struct InvidiousChannel
  db_mapping({
    id:         String,
    author:     String,
    updated:    Time,
    deleted:    Bool,
    subscribed: Time?,
  })
end

struct ChannelVideo
  def to_json(locale, config, kemal_config, json : JSON::Builder)
    json.object do
      json.field "type", "shortVideo"

      json.field "title", self.title
      json.field "videoId", self.id
      json.field "videoThumbnails" do
        generate_thumbnails(json, self.id, config, Kemal.config)
      end

      json.field "lengthSeconds", self.length_seconds

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", "/channel/#{self.ucid}"
      json.field "published", self.published.to_unix
      json.field "publishedText", translate(locale, "`x` ago", recode_date(self.published, locale))

      json.field "viewCount", self.views
    end
  end

  def to_json(locale, config, kemal_config, json : JSON::Builder | Nil = nil)
    if json
      to_json(locale, config, kemal_config, json)
    else
      JSON.build do |json|
        to_json(locale, config, kemal_config, json)
      end
    end
  end

  def to_xml(locale, host_url, xml : XML::Builder)
    xml.element("entry") do
      xml.element("id") { xml.text "yt:video:#{self.id}" }
      xml.element("yt:videoId") { xml.text self.id }
      xml.element("yt:channelId") { xml.text self.ucid }
      xml.element("title") { xml.text self.title }
      xml.element("link", rel: "alternate", href: "#{host_url}/watch?v=#{self.id}")

      xml.element("author") do
        xml.element("name") { xml.text self.author }
        xml.element("uri") { xml.text "#{host_url}/channel/#{self.ucid}" }
      end

      xml.element("content", type: "xhtml") do
        xml.element("div", xmlns: "http://www.w3.org/1999/xhtml") do
          xml.element("a", href: "#{host_url}/watch?v=#{self.id}") do
            xml.element("img", src: "#{host_url}/vi/#{self.id}/mqdefault.jpg")
          end
        end
      end

      xml.element("published") { xml.text self.published.to_s("%Y-%m-%dT%H:%M:%S%:z") }
      xml.element("updated") { xml.text self.updated.to_s("%Y-%m-%dT%H:%M:%S%:z") }

      xml.element("media:group") do
        xml.element("media:title") { xml.text self.title }
        xml.element("media:thumbnail", url: "#{host_url}/vi/#{self.id}/mqdefault.jpg",
          width: "320", height: "180")
      end
    end
  end

  def to_xml(locale, config, kemal_config, xml : XML::Builder | Nil = nil)
    if xml
      to_xml(locale, config, kemal_config, xml)
    else
      XML.build do |xml|
        to_xml(locale, config, kemal_config, xml)
      end
    end
  end

  db_mapping({
    id:                 String,
    title:              String,
    published:          Time,
    updated:            Time,
    ucid:               String,
    author:             String,
    length_seconds:     {type: Int32, default: 0},
    live_now:           {type: Bool, default: false},
    premiere_timestamp: {type: Time?, default: nil},
    views:              {type: Int64?, default: nil},
  })
end

struct AboutRelatedChannel
  db_mapping({
    ucid:             String,
    author:           String,
    author_url:       String,
    author_thumbnail: String,
  })
end

# TODO: Refactor into either SearchChannel or InvidiousChannel
struct AboutChannel
  db_mapping({
    ucid:               String,
    author:             String,
    auto_generated:     Bool,
    author_url:         String,
    author_thumbnail:   String,
    banner:             String?,
    description_html:   String,
    paid:               Bool,
    total_views:        Int64,
    sub_count:          Int64,
    joined:             Time,
    is_family_friendly: Bool,
    allowed_regions:    Array(String),
    related_channels:   Array(AboutRelatedChannel),
    tabs:               Array(String),
  })
end

def get_batch_channels(channels, db, refresh = false, pull_all_videos = true, max_threads = 10)
  finished_channel = Channel(String | Nil).new

  spawn do
    active_threads = 0
    active_channel = Channel(Nil).new

    channels.each do |ucid|
      if active_threads >= max_threads
        active_channel.receive
        active_threads -= 1
      end

      active_threads += 1
      spawn do
        begin
          get_channel(ucid, db, refresh, pull_all_videos)
          finished_channel.send(ucid)
        rescue ex
          finished_channel.send(nil)
        ensure
          active_channel.send(nil)
        end
      end
    end
  end

  final = [] of String
  channels.size.times do
    if ucid = finished_channel.receive
      final << ucid
    end
  end

  return final
end

def get_channel(id, db, refresh = true, pull_all_videos = true)
  if channel = db.query_one?("SELECT * FROM channels WHERE id = $1", id, as: InvidiousChannel)
    if refresh && Time.utc - channel.updated > 10.minutes
      channel = fetch_channel(id, db, pull_all_videos: pull_all_videos)
      channel_array = channel.to_a
      args = arg_array(channel_array)

      db.exec("INSERT INTO channels VALUES (#{args}) \
        ON CONFLICT (id) DO UPDATE SET author = $2, updated = $3", channel_array)
    end
  else
    channel = fetch_channel(id, db, pull_all_videos: pull_all_videos)
    channel_array = channel.to_a
    args = arg_array(channel_array)

    db.exec("INSERT INTO channels VALUES (#{args})", channel_array)
  end

  return channel
end

def fetch_channel(ucid, db, pull_all_videos = true, locale = nil)
  client = make_client(YT_URL)

  rss = client.get("/feeds/videos.xml?channel_id=#{ucid}").body
  rss = XML.parse_html(rss)

  author = rss.xpath_node(%q(//feed/title))
  if !author
    raise translate(locale, "Deleted or invalid channel")
  end
  author = author.content

  # Auto-generated channels
  # https://support.google.com/youtube/answer/2579942
  if author.ends_with?(" - Topic") ||
     {"Popular on YouTube", "Music", "Sports", "Gaming"}.includes? author
    auto_generated = true
  end

  page = 1

  url = produce_channel_videos_url(ucid, page, auto_generated: auto_generated)
  response = client.get(url)
  json = JSON.parse(response.body)

  if json["content_html"]? && !json["content_html"].as_s.empty?
    document = XML.parse_html(json["content_html"].as_s)
    nodeset = document.xpath_nodes(%q(//li[contains(@class, "feed-item-container")]))

    if auto_generated
      videos = extract_videos(nodeset)
    else
      videos = extract_videos(nodeset, ucid, author)
    end
  end

  videos ||= [] of ChannelVideo

  rss.xpath_nodes("//feed/entry").each do |entry|
    video_id = entry.xpath_node("videoid").not_nil!.content
    title = entry.xpath_node("title").not_nil!.content
    published = Time.parse_rfc3339(entry.xpath_node("published").not_nil!.content)
    updated = Time.parse_rfc3339(entry.xpath_node("updated").not_nil!.content)
    author = entry.xpath_node("author/name").not_nil!.content
    ucid = entry.xpath_node("channelid").not_nil!.content
    views = entry.xpath_node("group/community/statistics").try &.["views"]?.try &.to_i64?
    views ||= 0_i64

    channel_video = videos.select { |video| video.id == video_id }[0]?

    length_seconds = channel_video.try &.length_seconds
    length_seconds ||= 0

    live_now = channel_video.try &.live_now
    live_now ||= false

    premiere_timestamp = channel_video.try &.premiere_timestamp

    video = ChannelVideo.new(
      id: video_id,
      title: title,
      published: published,
      updated: Time.utc,
      ucid: ucid,
      author: author,
      length_seconds: length_seconds,
      live_now: live_now,
      premiere_timestamp: premiere_timestamp,
      views: views,
    )

    emails = db.query_all("UPDATE users SET notifications = notifications || $1 \
      WHERE updated < $2 AND $3 = ANY(subscriptions) AND $1 <> ALL(notifications) RETURNING email",
      video.id, video.published, ucid, as: String)

    video_array = video.to_a
    args = arg_array(video_array)

    # We don't include the 'premiere_timestamp' here because channel pages don't include them,
    # meaning the above timestamp is always null
    db.exec("INSERT INTO channel_videos VALUES (#{args}) \
      ON CONFLICT (id) DO UPDATE SET title = $2, published = $3, \
      updated = $4, ucid = $5, author = $6, length_seconds = $7, \
      live_now = $8, views = $10", video_array)

    # Update all users affected by insert
    if emails.empty?
      values = "'{}'"
    else
      values = "VALUES #{emails.map { |id| %(('#{id}')) }.join(",")}"
    end

    db.exec("UPDATE users SET feed_needs_update = true WHERE email = ANY(#{values})")
  end

  if pull_all_videos
    page += 1

    ids = [] of String

    loop do
      url = produce_channel_videos_url(ucid, page, auto_generated: auto_generated)
      response = client.get(url)
      json = JSON.parse(response.body)

      if json["content_html"]? && !json["content_html"].as_s.empty?
        document = XML.parse_html(json["content_html"].as_s)
        nodeset = document.xpath_nodes(%q(//li[contains(@class, "feed-item-container")]))
      else
        break
      end

      nodeset = nodeset.not_nil!

      if auto_generated
        videos = extract_videos(nodeset)
      else
        videos = extract_videos(nodeset, ucid, author)
      end

      count = nodeset.size
      videos = videos.map { |video| ChannelVideo.new(
        id: video.id,
        title: video.title,
        published: video.published,
        updated: Time.utc,
        ucid: video.ucid,
        author: video.author,
        length_seconds: video.length_seconds,
        live_now: video.live_now,
        premiere_timestamp: video.premiere_timestamp,
        views: video.views
      ) }

      videos.each do |video|
        ids << video.id

        # We are notified of Red videos elsewhere (PubSub), which includes a correct published date,
        # so since they don't provide a published date here we can safely ignore them.
        if Time.utc - video.published > 1.minute
          emails = db.query_all("UPDATE users SET notifications = notifications || $1 \
            WHERE updated < $2 AND $3 = ANY(subscriptions) AND $1 <> ALL(notifications) RETURNING email",
            video.id, video.published, video.ucid, as: String)

          video_array = video.to_a
          args = arg_array(video_array)

          # We don't update the 'premire_timestamp' here because channel pages don't include them
          db.exec("INSERT INTO channel_videos VALUES (#{args}) \
            ON CONFLICT (id) DO UPDATE SET title = $2, published = $3, \
            updated = $4, ucid = $5, author = $6, length_seconds = $7, \
            live_now = $8, views = $10", video_array)

          # Update all users affected by insert
          if emails.empty?
            values = "'{}'"
          else
            values = "VALUES #{emails.map { |id| %(('#{id}')) }.join(",")}"
          end

          db.exec("UPDATE users SET feed_needs_update = true WHERE email = ANY(#{values})")
        end
      end

      if count < 25
        break
      end

      page += 1
    end

    # When a video is deleted from a channel, we find and remove it here
    db.exec("DELETE FROM channel_videos * WHERE NOT id = ANY ('{#{ids.map { |id| %("#{id}") }.join(",")}}') AND ucid = $1", ucid)
  end

  channel = InvidiousChannel.new(ucid, author, Time.utc, false, nil)

  return channel
end

def fetch_channel_playlists(ucid, author, auto_generated, continuation, sort_by)
  client = make_client(YT_URL)

  if continuation
    url = produce_channel_playlists_url(ucid, continuation, sort_by, auto_generated)

    response = client.get(url)
    json = JSON.parse(response.body)

    if json["load_more_widget_html"].as_s.empty?
      return [] of SearchItem, nil
    end

    continuation = XML.parse_html(json["load_more_widget_html"].as_s)
    continuation = continuation.xpath_node(%q(//button[@data-uix-load-more-href]))
    if continuation
      continuation = extract_channel_playlists_cursor(continuation["data-uix-load-more-href"], auto_generated)
    end

    html = XML.parse_html(json["content_html"].as_s)
    nodeset = html.xpath_nodes(%q(//li[contains(@class, "feed-item-container")]))
  else
    url = "/channel/#{ucid}/playlists?disable_polymer=1&flow=list"

    if auto_generated
      url += "&view=50"
    else
      url += "&view=1"
    end

    case sort_by
    when "last", "last_added"
      #
    when "oldest", "oldest_created"
      url += "&sort=da"
    when "newest", "newest_created"
      url += "&sort=dd"
    end

    response = client.get(url)
    html = XML.parse_html(response.body)

    continuation = html.xpath_node(%q(//button[@data-uix-load-more-href]))
    if continuation
      continuation = extract_channel_playlists_cursor(continuation["data-uix-load-more-href"], auto_generated)
    end

    nodeset = html.xpath_nodes(%q(//ul[@id="browse-items-primary"]/li[contains(@class, "feed-item-container")]))
  end

  if auto_generated
    items = extract_shelf_items(nodeset, ucid, author)
  else
    items = extract_items(nodeset, ucid, author)
  end

  return items, continuation
end

def produce_channel_videos_url(ucid, page = 1, auto_generated = nil, sort_by = "newest")
  if auto_generated
    seed = Time.unix(1525757349)

    until seed >= Time.utc
      seed += 1.month
    end
    timestamp = seed - (page - 1).months

    page = "#{timestamp.to_unix}"
    switch = 0x36
  else
    page = "#{page}"
    switch = 0x00
  end

  meta = IO::Memory.new
  meta.write(Bytes[0x12, 0x06])
  meta.print("videos")

  meta.write(Bytes[0x30, 0x02])
  meta.write(Bytes[0x38, 0x01])
  meta.write(Bytes[0x60, 0x01])
  meta.write(Bytes[0x6a, 0x00])
  meta.write(Bytes[0xb8, 0x01, 0x00])

  meta.write(Bytes[0x20, switch])
  meta.write(Bytes[0x7a, page.size])
  meta.print(page)

  case sort_by
  when "newest"
    # Empty tags can be omitted
    # meta.write(Bytes[0x18,0x00])
  when "popular"
    meta.write(Bytes[0x18, 0x01])
  when "oldest"
    meta.write(Bytes[0x18, 0x02])
  end

  meta.rewind
  meta = Base64.urlsafe_encode(meta.to_slice)
  meta = URI.escape(meta)

  continuation = IO::Memory.new
  continuation.write(Bytes[0x12, ucid.size])
  continuation.print(ucid)

  continuation.write(Bytes[0x1a, meta.size])
  continuation.print(meta)

  continuation.rewind
  continuation = continuation.gets_to_end

  wrapper = IO::Memory.new
  wrapper.write(Bytes[0xe2, 0xa9, 0x85, 0xb2, 0x02, continuation.size])
  wrapper.print(continuation)
  wrapper.rewind

  wrapper = Base64.urlsafe_encode(wrapper.to_slice)
  wrapper = URI.escape(wrapper)

  url = "/browse_ajax?continuation=#{wrapper}&gl=US&hl=en"

  return url
end

def produce_channel_playlists_url(ucid, cursor, sort = "newest", auto_generated = false)
  if !auto_generated
    cursor = Base64.urlsafe_encode(cursor, false)
  end

  meta = IO::Memory.new

  if auto_generated
    meta.write(Bytes[0x08, 0x0a])
  end

  meta.write(Bytes[0x12, 0x09])
  meta.print("playlists")

  if auto_generated
    meta.write(Bytes[0x20, 0x32])
  else
    # TODO: Look at 0x01, 0x00
    case sort
    when "oldest", "oldest_created"
      meta.write(Bytes[0x18, 0x02])
    when "newest", "newest_created"
      meta.write(Bytes[0x18, 0x03])
    when "last", "last_added"
      meta.write(Bytes[0x18, 0x04])
    end

    meta.write(Bytes[0x20, 0x01])
  end

  meta.write(Bytes[0x30, 0x02])
  meta.write(Bytes[0x38, 0x01])
  meta.write(Bytes[0x60, 0x01])
  meta.write(Bytes[0x6a, 0x00])

  meta.write(Bytes[0x7a, cursor.size])
  meta.print(cursor)

  meta.write(Bytes[0xb8, 0x01, 0x00])

  meta.rewind
  meta = Base64.urlsafe_encode(meta.to_slice)
  meta = URI.escape(meta)

  continuation = IO::Memory.new
  continuation.write(Bytes[0x12, ucid.size])
  continuation.print(ucid)

  continuation.write(Bytes[0x1a])
  continuation.write(write_var_int(meta.size))
  continuation.print(meta)

  continuation.rewind
  continuation = continuation.gets_to_end

  wrapper = IO::Memory.new
  wrapper.write(Bytes[0xe2, 0xa9, 0x85, 0xb2, 0x02])
  wrapper.write(write_var_int(continuation.size))
  wrapper.print(continuation)
  wrapper.rewind

  wrapper = Base64.urlsafe_encode(wrapper.to_slice)
  wrapper = URI.escape(wrapper)

  url = "/browse_ajax?continuation=#{wrapper}&gl=US&hl=en"

  return url
end

def extract_channel_playlists_cursor(url, auto_generated)
  wrapper = HTTP::Params.parse(URI.parse(url).query.not_nil!)["continuation"]

  wrapper = URI.unescape(wrapper)
  wrapper = Base64.decode(wrapper)

  # 0xe2 0xa9 0x85 0xb2 0x02
  wrapper += 5

  continuation_size = read_var_int(wrapper[0, 4])
  wrapper += write_var_int(continuation_size).size
  continuation = wrapper[0, continuation_size]

  # 0x12
  continuation += 1
  ucid_size = continuation[0]
  continuation += 1
  ucid = continuation[0, ucid_size]
  continuation += ucid_size

  # 0x1a
  continuation += 1
  meta_size = read_var_int(continuation[0, 4])
  continuation += write_var_int(meta_size).size
  meta = continuation[0, meta_size]
  continuation += meta_size

  meta = String.new(meta)
  meta = URI.unescape(meta)
  meta = Base64.decode(meta)

  # 0x12 0x09 playlists
  meta += 11

  until meta[0] == 0x7a
    tag = read_var_int(meta[0, 4])
    meta += write_var_int(tag).size
    value = meta[0]
    meta += 1
  end

  # 0x7a
  meta += 1
  cursor_size = meta[0]
  meta += 1
  cursor = meta[0, cursor_size]

  cursor = String.new(cursor)

  if !auto_generated
    cursor = URI.unescape(cursor)
    cursor = Base64.decode_string(cursor)
  end

  return cursor
end

# TODO: Add "sort_by"
def fetch_channel_community(ucid, continuation, locale, config, kemal_config, format, thin_mode)
  client = make_client(YT_URL)
  headers = HTTP::Headers.new
  headers["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/68.0.3440.106 Safari/537.36"

  response = client.get("/channel/#{ucid}/community?gl=US&hl=en", headers)
  if response.status_code == 404
    response = client.get("/user/#{ucid}/community?gl=US&hl=en", headers)
  end

  if response.status_code == 404
    error_message = translate(locale, "This channel does not exist.")
    raise error_message
  end

  ucid = response.body.match(/https:\/\/www.youtube.com\/channel\/(?<ucid>UC[a-zA-Z0-9_-]{22})/).not_nil!["ucid"]

  if !continuation || continuation.empty?
    response = JSON.parse(response.body.match(/window\["ytInitialData"\] = (?<info>.*?);\n/).try &.["info"] || "{}")
    body = response["contents"]?.try &.["twoColumnBrowseResultsRenderer"]["tabs"].as_a.select { |tab| tab["tabRenderer"]?.try &.["selected"].as_bool.== true }[0]?

    if !body
      raise "Could not extract community tab."
    end

    body = body["tabRenderer"]["content"]["sectionListRenderer"]["contents"][0]["itemSectionRenderer"]
  else
    continuation = produce_channel_community_continuation(ucid, continuation)

    headers["cookie"] = response.cookies.add_request_headers(headers)["cookie"]
    headers["content-type"] = "application/x-www-form-urlencoded"

    headers["x-client-data"] = "CIi2yQEIpbbJAQipncoBCNedygEIqKPKAQ=="
    headers["x-spf-previous"] = ""
    headers["x-spf-referer"] = ""

    headers["x-youtube-client-name"] = "1"
    headers["x-youtube-client-version"] = "2.20180719"

    session_token = response.body.match(/"XSRF_TOKEN":"(?<session_token>[A-Za-z0-9\_\-\=]+)"/).try &.["session_token"]? || ""
    post_req = {
      session_token: session_token,
    }

    response = client.post("/comment_service_ajax?action_get_comments=1&ctoken=#{continuation}&continuation=#{continuation}&hl=en&gl=US", headers, form: post_req)
    body = JSON.parse(response.body)

    body = body["response"]["continuationContents"]["itemSectionContinuation"]? ||
           body["response"]["continuationContents"]["backstageCommentsContinuation"]?

    if !body
      raise "Could not extract continuation."
    end
  end

  continuation = body["continuations"]?.try &.[0]["nextContinuationData"]["continuation"].as_s
  posts = body["contents"].as_a

  if message = posts[0]["messageRenderer"]?
    error_message = (message["text"]["simpleText"]? ||
                     message["text"]["runs"]?.try &.[0]?.try &.["text"]?)
      .try &.as_s || ""
    raise error_message
  end

  response = JSON.build do |json|
    json.object do
      json.field "authorId", ucid
      json.field "comments" do
        json.array do
          posts.each do |post|
            comments = post["backstagePostThreadRenderer"]?.try &.["comments"]? ||
                       post["backstageCommentsContinuation"]?

            post = post["backstagePostThreadRenderer"]?.try &.["post"]["backstagePostRenderer"]? ||
                   post["commentThreadRenderer"]?.try &.["comment"]["commentRenderer"]?

            if !post
              next
            end

            if !post["contentText"]?
              content_html = ""
            else
              content_html = post["contentText"]["simpleText"]?.try &.as_s.rchop('\ufeff').try { |block| HTML.escape(block) }.to_s ||
                             content_to_comment_html(post["contentText"]["runs"].as_a).try &.to_s || ""
            end

            author = post["authorText"]?.try &.["simpleText"]? || ""

            json.object do
              json.field "author", author
              json.field "authorThumbnails" do
                json.array do
                  qualities = {32, 48, 76, 100, 176, 512}
                  author_thumbnail = post["authorThumbnail"]["thumbnails"].as_a[0]["url"].as_s

                  qualities.each do |quality|
                    json.object do
                      json.field "url", author_thumbnail.gsub(/s\d+-/, "s#{quality}-")
                      json.field "width", quality
                      json.field "height", quality
                    end
                  end
                end
              end

              if post["authorEndpoint"]?
                json.field "authorId", post["authorEndpoint"]["browseEndpoint"]["browseId"]
                json.field "authorUrl", post["authorEndpoint"]["commandMetadata"]["webCommandMetadata"]["url"].as_s
              else
                json.field "authorId", ""
                json.field "authorUrl", ""
              end

              published_text = post["publishedTimeText"]["runs"][0]["text"].as_s
              published = decode_date(published_text.rchop(" (edited)"))

              if published_text.includes?(" (edited)")
                json.field "isEdited", true
              else
                json.field "isEdited", false
              end

              like_count = post["actionButtons"]["commentActionButtonsRenderer"]["likeButton"]["toggleButtonRenderer"]["accessibilityData"]["accessibilityData"]["label"]
                .try &.as_s.gsub(/\D/, "").to_i? || 0

              json.field "content", html_to_content(content_html)
              json.field "contentHtml", content_html

              json.field "published", published.to_unix
              json.field "publishedText", translate(locale, "`x` ago", recode_date(published, locale))

              json.field "likeCount", like_count
              json.field "commentId", post["postId"]? || post["commentId"]? || ""
              json.field "authorIsChannelOwner", post["authorEndpoint"]["browseEndpoint"]["browseId"] == ucid

              if attachment = post["backstageAttachment"]?
                json.field "attachment" do
                  json.object do
                    case attachment.as_h
                    when .has_key?("videoRenderer")
                      attachment = attachment["videoRenderer"]
                      json.field "type", "video"

                      if !attachment["videoId"]?
                        error_message = (attachment["title"]["simpleText"]? ||
                                         attachment["title"]["runs"]?.try &.[0]?.try &.["text"]?)

                        json.field "error", error_message
                      else
                        video_id = attachment["videoId"].as_s

                        json.field "title", attachment["title"]["simpleText"].as_s
                        json.field "videoId", video_id
                        json.field "videoThumbnails" do
                          generate_thumbnails(json, video_id, config, kemal_config)
                        end

                        json.field "lengthSeconds", decode_length_seconds(attachment["lengthText"]["simpleText"].as_s)

                        author_info = attachment["ownerText"]["runs"][0].as_h

                        json.field "author", author_info["text"].as_s
                        json.field "authorId", author_info["navigationEndpoint"]["browseEndpoint"]["browseId"]
                        json.field "authorUrl", author_info["navigationEndpoint"]["commandMetadata"]["webCommandMetadata"]["url"]

                        # TODO: json.field "authorThumbnails", "channelThumbnailSupportedRenderers"
                        # TODO: json.field "authorVerified", "ownerBadges"

                        published = decode_date(attachment["publishedTimeText"]["simpleText"].as_s)

                        json.field "published", published.to_unix
                        json.field "publishedText", translate(locale, "`x` ago", recode_date(published, locale))

                        view_count = attachment["viewCountText"]["simpleText"].as_s.gsub(/\D/, "").to_i64? || 0_i64

                        json.field "viewCount", view_count
                        json.field "viewCountText", translate(locale, "`x` views", number_to_short_text(view_count))
                      end
                    when .has_key?("backstageImageRenderer")
                      attachment = attachment["backstageImageRenderer"]
                      json.field "type", "image"

                      json.field "imageThumbnails" do
                        json.array do
                          thumbnail = attachment["image"]["thumbnails"][0].as_h
                          width = thumbnail["width"].as_i
                          height = thumbnail["height"].as_i
                          aspect_ratio = (width.to_f / height.to_f)

                          qualities = {320, 560, 640, 1280, 2000}

                          qualities.each do |quality|
                            json.object do
                              json.field "url", thumbnail["url"].as_s.gsub("=s640-", "=s#{quality}-")
                              json.field "width", quality
                              json.field "height", (quality / aspect_ratio).ceil.to_i
                            end
                          end
                        end
                      end
                    else
                      # TODO
                    end
                  end
                end
              end

              if comments && (reply_count = (comments["backstageCommentsRenderer"]["moreText"]["simpleText"]? ||
                                             comments["backstageCommentsRenderer"]["moreText"]["runs"]?.try &.[0]?.try &.["text"]?)
                   .try &.as_s.gsub(/\D/, "").to_i?)
                continuation = comments["backstageCommentsRenderer"]["continuations"]?.try &.as_a[0]["nextContinuationData"]["continuation"].as_s
                continuation ||= ""

                json.field "replies" do
                  json.object do
                    json.field "replyCount", reply_count
                    json.field "continuation", extract_channel_community_cursor(continuation)
                  end
                end
              end
            end
          end
        end
      end

      if body["continuations"]?
        continuation = body["continuations"][0]["nextContinuationData"]["continuation"].as_s
        json.field "continuation", extract_channel_community_cursor(continuation)
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    content_html = template_youtube_comments(response, locale, thin_mode)

    response = JSON.build do |json|
      json.object do
        json.field "contentHtml", content_html
      end
    end
  end

  return response
end

def produce_channel_community_continuation(ucid, cursor)
  cursor = URI.escape(cursor)
  continuation = IO::Memory.new

  continuation.write(Bytes[0xe2, 0xa9, 0x85, 0xb2, 0x02])
  continuation.write(write_var_int(3 + ucid.size + write_var_int(cursor.size).size + cursor.size))

  continuation.write(Bytes[0x12, ucid.size])
  continuation.print(ucid)

  continuation.write(Bytes[0x1a])
  continuation.write(write_var_int(cursor.size))
  continuation.print(cursor)
  continuation.rewind

  continuation = Base64.urlsafe_encode(continuation.to_slice)
  continuation = URI.escape(continuation)

  return continuation
end

def extract_channel_community_cursor(continuation)
  continuation = URI.unescape(continuation)
  continuation = Base64.decode(continuation)

  # 0xe2 0xa9 0x85 0xb2 0x02
  continuation += 5

  total_size = read_var_int(continuation[0, 4])
  continuation += write_var_int(total_size).size

  # 0x12
  continuation += 1
  ucid_size = continuation[0]
  continuation += 1
  ucid = continuation[0, ucid_size]
  continuation += ucid_size

  # 0x1a
  continuation += 1
  until continuation[0] == 'E'.ord
    continuation += 1
  end

  return String.new(continuation)
end

def get_about_info(ucid, locale)
  client = make_client(YT_URL)

  about = client.get("/channel/#{ucid}/about?disable_polymer=1&gl=US&hl=en")
  if about.status_code == 404
    about = client.get("/user/#{ucid}/about?disable_polymer=1&gl=US&hl=en")
  end

  about = XML.parse_html(about.body)

  if about.xpath_node(%q(//div[contains(@class, "channel-empty-message")]))
    error_message = translate(locale, "This channel does not exist.")
    raise error_message
  end

  if about.xpath_node(%q(//span[contains(@class,"qualified-channel-title-text")]/a)).try &.content.empty?
    error_message = about.xpath_node(%q(//div[@class="yt-alert-content"])).try &.content.strip
    error_message ||= translate(locale, "Could not get channel info.")
    raise error_message
  end

  sub_count = about.xpath_node(%q(//span[contains(text(), "subscribers")]))
  if sub_count
    sub_count = sub_count.content.delete(", subscribers").to_i?
  end
  sub_count ||= 0

  author = about.xpath_node(%q(//span[contains(@class,"qualified-channel-title-text")]/a)).not_nil!.content
  author_url = about.xpath_node(%q(//span[contains(@class,"qualified-channel-title-text")]/a)).not_nil!["href"]
  author_thumbnail = about.xpath_node(%q(//img[@class="channel-header-profile-image"])).not_nil!["src"]

  ucid = about.xpath_node(%q(//meta[@itemprop="channelId"])).not_nil!["content"]

  banner = about.xpath_node(%q(//div[@id="gh-banner"]/style)).not_nil!.content
  banner = "https:" + banner.match(/background-image: url\((?<url>[^)]+)\)/).not_nil!["url"]

  if banner.includes? "channels/c4/default_banner"
    banner = nil
  end

  description_html = about.xpath_node(%q(//div[contains(@class,"about-description")])).try &.to_s || ""

  paid = about.xpath_node(%q(//meta[@itemprop="paid"])).not_nil!["content"] == "True"
  is_family_friendly = about.xpath_node(%q(//meta[@itemprop="isFamilyFriendly"])).not_nil!["content"] == "True"
  allowed_regions = about.xpath_node(%q(//meta[@itemprop="regionsAllowed"])).not_nil!["content"].split(",")

  related_channels = about.xpath_nodes(%q(//div[contains(@class, "branded-page-related-channels")]/ul/li))
  related_channels = related_channels.map do |node|
    related_id = node["data-external-id"]?
    related_id ||= ""

    anchor = node.xpath_node(%q(.//h3[contains(@class, "yt-lockup-title")]/a))
    related_title = anchor.try &.["title"]
    related_title ||= ""

    related_author_url = anchor.try &.["href"]
    related_author_url ||= ""

    related_author_thumbnail = node.xpath_node(%q(.//img)).try &.["data-thumb"]
    related_author_thumbnail ||= ""

    AboutRelatedChannel.new(
      ucid: related_id,
      author: related_title,
      author_url: related_author_url,
      author_thumbnail: related_author_thumbnail,
    )
  end

  total_views = 0_i64
  sub_count = 0_i64

  joined = Time.unix(0)
  metadata = about.xpath_nodes(%q(//span[@class="about-stat"]))
  metadata.each do |item|
    case item.content
    when .includes? "views"
      total_views = item.content.gsub(/\D/, "").to_i64
    when .includes? "subscribers"
      sub_count = item.content.delete("subscribers").gsub(/\D/, "").to_i64
    when .includes? "Joined"
      joined = Time.parse(item.content.lchop("Joined "), "%b %-d, %Y", Time::Location.local)
    end
  end

  # Auto-generated channels
  # https://support.google.com/youtube/answer/2579942
  auto_generated = false
  if about.xpath_node(%q(//ul[@class="about-custom-links"]/li/a[@title="Auto-generated by YouTube"])) ||
     about.xpath_node(%q(//span[@class="qualified-channel-title-badge"]/span[@title="Auto-generated by YouTube"]))
    auto_generated = true
  end

  tabs = about.xpath_nodes(%q(//ul[@id="channel-navigation-menu"]/li/a/span)).map { |node| node.content.downcase }

  return AboutChannel.new(
    ucid: ucid,
    author: author,
    auto_generated: auto_generated,
    author_url: author_url,
    author_thumbnail: author_thumbnail,
    banner: banner,
    description_html: description_html,
    paid: paid,
    total_views: total_views,
    sub_count: sub_count,
    joined: joined,
    is_family_friendly: is_family_friendly,
    allowed_regions: allowed_regions,
    related_channels: related_channels,
    tabs: tabs
  )
end

def get_60_videos(ucid, author, page, auto_generated, sort_by = "newest")
  count = 0
  videos = [] of SearchVideo

  client = make_client(YT_URL)

  2.times do |i|
    url = produce_channel_videos_url(ucid, page * 2 + (i - 1), auto_generated: auto_generated, sort_by: sort_by)
    response = client.get(url)
    json = JSON.parse(response.body)

    if json["content_html"]? && !json["content_html"].as_s.empty?
      document = XML.parse_html(json["content_html"].as_s)
      nodeset = document.xpath_nodes(%q(//li[contains(@class, "feed-item-container")]))

      if !json["load_more_widget_html"]?.try &.as_s.empty?
        count += 30
      end

      if auto_generated
        videos += extract_videos(nodeset)
      else
        videos += extract_videos(nodeset, ucid, author)
      end
    else
      break
    end
  end

  return videos, count
end

def get_latest_videos(ucid)
  client = make_client(YT_URL)
  videos = [] of SearchVideo

  url = produce_channel_videos_url(ucid, 0)
  response = client.get(url)
  json = JSON.parse(response.body)

  if json["content_html"]? && !json["content_html"].as_s.empty?
    document = XML.parse_html(json["content_html"].as_s)
    nodeset = document.xpath_nodes(%q(//li[contains(@class, "feed-item-container")]))

    videos = extract_videos(nodeset, ucid)
  end

  return videos
end
