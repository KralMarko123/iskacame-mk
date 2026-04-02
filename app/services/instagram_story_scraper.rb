require "json"
require "set"
require "fileutils"
require "uri"
require "cgi"

class InstagramStoryScraper
  MAX_STORIES = 50

  def initialize(profile_username:)
    @profile_username = profile_username
  end

  def call
    storage_state_path = ENV.fetch("INSTAGRAM_STORAGE_STATE_PATH", "tmp/instagram_auth.json")
    raise "Missing Instagram auth state at #{storage_state_path}" unless File.exist?(storage_state_path)

    Playwright.create(
      playwright_cli_executable_path: ENV.fetch("PLAYWRIGHT_CLI_EXECUTABLE_PATH", "npx playwright")
    ) do |playwright|
      browser = playwright.chromium.launch(headless: false)
      context = browser.new_context(
        ignoreHTTPSErrors: true,
        storageState: storage_state_path
      )
      page = context.new_page

      begin
        current_frame_media = []

        page.on("response", ->(response) do
          begin
            url = response.url
            next unless story_media_url?(url)

            current_frame_media << {
              url: url,
              content_type: response.header_value("content-type")
            }
          rescue => e
            puts "Response capture error: #{e.message}"
          end
        end)

        page.goto(story_url, waitUntil: "domcontentloaded", timeout: 30_000)
        page.wait_for_timeout(1500)

        entered = click_story_entry_prompt(page)

        unless entered
          return inactive_payload
        end

        page.wait_for_timeout(1000)

        unless story_view_active_for_target?(page)
          return inactive_payload
        end

        items = collect_story_frames(page, current_frame_media)
        downloaded_items = StoryMediaDownloader.new(items: items).call

        {
          active: downloaded_items.any?,
          source: profile_username,
          fetched_at: Time.current.iso8601,
          expires_at: Time.current.end_of_day.iso8601,
          items: downloaded_items
        }
      ensure
        context.close
        browser.close
      end
    end
  end

  private

  attr_reader :profile_username

  def story_url
    "https://www.instagram.com/stories/#{profile_username}/"
  end

  def click_story_entry_prompt(page)
    locator = page.locator('div[role="button"]', hasText: "View story")
    return false if locator.count == 0

    button = locator.first
    button.scroll_into_view_if_needed
    page.wait_for_timeout(500)

    begin
      button.click(force: true, timeout: 5_000)
    rescue
      begin
        button.dispatch_event("click")
      rescue
        button.evaluate("el => el.click()")
      end
    end

    page.wait_for_timeout(3000)
    true
  end

  def collect_story_frames(page, current_frame_media)
    items = []
    seen_urls = Set.new
    consecutive_misses = 0

    MAX_STORIES.times do |index|
      owner = current_story_owner(page)
      puts "Current story owner: #{owner.inspect}"

      if owner.present? && owner.downcase != profile_username.downcase
        puts "Stopping: viewer moved from #{profile_username} to #{owner}"
        break
      end

      puts "Frame buffer size before extract: #{current_frame_media.size}"

      current_item = extract_current_frame(page, current_frame_media)

      if current_item && !seen_urls.include?(current_item[:media_url])
        seen_urls << current_item[:media_url]
        current_item[:order] = items.length + 1
        items << current_item
        consecutive_misses = 0
        puts "Captured frame #{items.length}: #{current_item[:type]} #{current_item[:media_url]}"
      else
        consecutive_misses += 1
        puts "No new frame captured at step #{index + 1}"
      end

      break if consecutive_misses >= 2

      current_frame_media.clear
      break unless click_next_story(page)

      # shorter wait so we do not skip the next frame
      page.wait_for_timeout(900)

      # if moving next immediately exits target story set, stop
      break unless story_view_active_for_target?(page)
    end

    items
  end

  def inactive_payload
    {
      active: false,
      source: profile_username,
      fetched_at: Time.current.iso8601,
      expires_at: Time.current.end_of_day.iso8601,
      items: []
    }
  end

  def story_view_active_for_target?(page)
    owner = current_story_owner(page)
    return true if owner.present? && owner.downcase == profile_username.downcase

    body_text = page.text_content("body").to_s.downcase

    return false if body_text.include?("this story is unavailable")
    return false if body_text.include?("story is unavailable")
    return false if body_text.include?("page isn't available")
    return false if body_text.include?("sorry, this page")
    return false if body_text.include?("no longer available")

    # if no owner and no prompt, assume there is no active story viewer
    prompt = page.locator('div[role="button"]', hasText: "View story")
    return false if owner.blank? && prompt.count == 0

    true
  rescue => e
    puts "story_view_active_for_target? error: #{e.message}"
    false
  end

  def extract_current_frame(page, current_frame_media)
    dom_item = extract_current_frame_from_dom(page)
    return dom_item if dom_item.present?

    latest_image = current_frame_media.reverse.find do |entry|
      url = entry[:url]
      usable_story_media?(url) && image_story_url?(url)
    end

    if latest_image
      return {
        type: "image",
        media_url: latest_image[:url]
      }
    end

    latest_video = current_frame_media.reverse.find do |entry|
      url = entry[:url]
      usable_story_media?(url) && video_story_url?(url)
    end

    if latest_video
      return {
        type: "video",
        media_url: normalize_video_url(latest_video[:url]),
        fallback_image_url: screenshot_current_story_frame(page)
      }
    end

    {
      type: "image",
      media_url: screenshot_current_story_frame(page)
    }
  end

  def extract_current_frame_from_dom(page)
    selectors = [
      '[role="dialog"] img',
      '[role="dialog"] video',
      "main img",
      "main video",
      "article img",
      "article video"
    ]

    selectors.each do |selector|
      begin
        locator = page.locator(selector)
        count = locator.count
        next if count == 0

        (0...count).each do |i|
          node = locator.nth(i)

          src = node.get_attribute("src")
          poster = node.get_attribute("poster")
          tag_name = node.evaluate("el => el.tagName.toLowerCase()") rescue nil

          if tag_name == "img"
            next if src.blank?
            next unless valid_story_image_candidate?(src)

            return {
              type: "image",
              media_url: src
            }
          end

          if tag_name == "video"
            if src.present? && valid_story_video_candidate?(src)
              return {
                type: "video",
                media_url: normalize_video_url(src),
                fallback_image_url: screenshot_current_story_frame(page)
              }
            end

            if poster.present? && valid_story_image_candidate?(poster)
              return {
                type: "image",
                media_url: poster
              }
            end
          end
        end
      rescue => e
        puts "DOM extract error for #{selector}: #{e.message}"
      end
    end

    nil
  end

  def screenshot_current_story_frame(page)
    output_dir = Rails.root.join("public", "tmp", "story_frames")
    FileUtils.mkdir_p(output_dir)

    filename = "story_frame_#{Time.current.to_i}_#{rand(1000..9999)}.png"
    absolute_path = output_dir.join(filename)

    box = centered_story_content_box(page)

    page.screenshot(
      path: absolute_path.to_s,
      clip: box
    )

    "/tmp/story_frames/#{filename}"
  end

  def centered_story_content_box(page)
    viewport = safe_viewport_size(page)

    width = viewport[:width] || viewport["width"]
    height = viewport[:height] || viewport["height"]

    raise "Viewport width missing: #{viewport.inspect}" if width.nil?
    raise "Viewport height missing: #{viewport.inspect}" if height.nil?

    width = width.to_f
    height = height.to_f

    crop_width = width * 0.3
    crop_height = height * 0.86

    x = ((width - crop_width) / 2.0) - 5
    y = height * 0.12

    {
      x: x,
      y: y,
      width: crop_width,
      height: crop_height
    }
  end

  def safe_viewport_size(page)
    viewport = page.viewport_size

    width =
      if viewport.respond_to?(:[])
        viewport[:width] || viewport["width"]
      end

    height =
      if viewport.respond_to?(:[])
        viewport[:height] || viewport["height"]
      end

    if width.present? && height.present?
      return { width: width, height: height }
    end

    width = page.evaluate("window.innerWidth")
    height = page.evaluate("window.innerHeight")

    if width.present? && height.present?
      return { width: width, height: height }
    end

    width = page.evaluate("document.documentElement.clientWidth")
    height = page.evaluate("document.documentElement.clientHeight")

    if width.present? && height.present?
      return { width: width, height: height }
    end

    raise "Could not determine viewport size"
  end

  def click_next_story(page)
    selectors = %w[svg[aria-label="Next"] button[aria-label="Next"] div[role="button"][aria-label="Next"]]

    selectors.each do |selector|
      begin
        locator = page.locator(selector)
        next if locator.count == 0

        locator.first.click(force: true, timeout: 3_000)
        page.wait_for_timeout(1500)
        return true
      rescue
        next
      end
    end

    begin
      page.keyboard.press("ArrowRight")
      page.wait_for_timeout(1500)
      true
    rescue
      false
    end
  end

  def story_media_url?(url)
    return false if url.blank?
    return false if url.start_with?("blob:")
    return false if likely_avatar?(url)
    return false if instagram_ui_asset?(url)

    # only accept real story media hosts
    return false unless story_media_host?(url)

    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png") || url.include?(".webp") || url.include?(".mp4")
  end

  def usable_story_media?(url)
    story_media_url?(url)
  end

  def image_story_url?(url)
    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png") || url.include?(".webp")
  end

  def valid_story_image_candidate?(url)
    return false if url.blank?
    return false if likely_avatar?(url)
    return false if instagram_ui_asset?(url)

    # DOM candidates can be story CDN URLs or already-local screenshot paths
    return true if url.start_with?("/tmp/story_frames/")
    return true if story_media_host?(url) && image_story_url?(url)

    false
  end

  def story_media_host?(url)
    url.include?("scontent-") ||
      url.include?(".fbcdn.net") ||
      url.include?("instagram.f") ||
      url.include?("cdninstagram.com/v/")
  end

  def instagram_ui_asset?(url)
    url.include?("static.cdninstagram.com") ||
      url.include?("/rsrc.php/") ||
      url.include?("instagram.com/static/")
  end

  def likely_avatar?(src)
    src.include?("s150x150") || src.include?("/t51.2885-19/")
  end

  def current_story_owner(page)
    selectors = [
      'header a[href^="/"]',
      'a[href^="/"]'
    ]

    selectors.each do |selector|
      begin
        locator = page.locator(selector)
        count = locator.count

        (0...count).each do |i|
          href = locator.nth(i).get_attribute("href")
          next if href.blank?
          next unless href.match?(%r{^/[^/]+/?$})

          username = href.delete_prefix("/").delete_suffix("/")
          next if username.blank?
          next if %w[stories explore accounts].include?(username)

          return username
        end
      rescue
        next
      end
    end

    nil
  end

  def video_story_url?(url)
    url.include?(".mp4")
  end

  def valid_story_video_candidate?(url)
    return false if url.blank?
    return false if url.start_with?("blob:")
    return false if instagram_ui_asset?(url)
    return false unless story_media_host?(url)

    video_story_url?(url)
  end

  def normalize_video_url(url)
    return url if url.blank?
    return url unless url.include?(".mp4")

    uri = URI.parse(url)
    params = CGI.parse(uri.query.to_s)
    params.delete("bytestart")
    params.delete("byteend")
    uri.query = URI.encode_www_form(params.transform_values(&:first))
    uri.to_s
  rescue
    url
  end
end
