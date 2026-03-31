require "json"
require "set"

class InstagramStoryScraper
  MAX_STORIES = 20

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
        page.wait_for_timeout(4000)

        click_story_entry_prompt(page)
        page.wait_for_timeout(2000)

        page.goto(story_url, waitUntil: "domcontentloaded", timeout: 30_000)
        page.wait_for_timeout(3000)
        click_story_entry_prompt(page)
        page.wait_for_timeout(3000)

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

    page.wait_for_timeout(2500)

    MAX_STORIES.times do |index|
      owner = current_story_owner(page)
      puts "Current story owner: #{owner.inspect}"

      if owner.present? && owner.downcase != profile_username.downcase
        puts "Stopping: viewer moved from #{profile_username} to #{owner}"
        break
      end

      puts "Frame buffer size before extract: #{current_frame_media.size}"

      current_item = extract_current_frame_as_image(page, current_frame_media)

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

      page.wait_for_timeout(2500)
    end

    items
  end

  def extract_current_frame_as_image(page, current_frame_media)
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
      usable_story_media?(url) && url.include?(".mp4")
    end

    if latest_video
      return {
        type: "image",
        media_url: screenshot_current_story_frame(page)
      }
    end

    nil
  end

  def extract_current_frame_from_dom(page)
    video_nodes = page.locator("video")
    if video_nodes.count > 0
      poster = video_nodes.first.get_attribute("poster")
      if poster.present? && !likely_avatar?(poster)
        return { type: "image", media_url: poster }
      end
    end

    image_nodes = page.locator("img")
    (0...image_nodes.count).each do |i|
      src = image_nodes.nth(i).get_attribute("src")
      next if src.blank?
      next if likely_avatar?(src)
      next unless src.include?("instagram")

      return { type: "image", media_url: src }
    end

    nil
  end

  def screenshot_current_story_frame(page)
    output_dir = Rails.root.join("public", "tmp", "story_frames")
    FileUtils.mkdir_p(output_dir)

    filename = "story_frame_#{Time.current.to_i}_#{rand(1000..9999)}.png"
    absolute_path = output_dir.join(filename)

    selectors = [
      "video",
      "img",
      '[role="dialog"] img',
      '[role="dialog"] video',
      "main img",
      "main video"
    ]

    selectors.each do |selector|
      begin
        locator = page.locator(selector)
        next if locator.count == 0

        element = locator.first
        box = element.bounding_box
        next if box.nil?

        page.screenshot(
          path: absolute_path.to_s,
          clip: {
            x: box["x"],
            y: box["y"],
            width: box["width"],
            height: box["height"]
          }
        )

        return "/tmp/story_frames/#{filename}"
      rescue
        next
      end
    end

    page.screenshot(path: absolute_path.to_s)
    "/tmp/story_frames/#{filename}"
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
    return false if url.include?("clips")
    return false unless url.include?("fbcdn.net") || url.include?("cdninstagram.com")

    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png") || url.include?(".webp") || url.include?(".mp4")
  end

  def usable_story_media?(url)
    story_media_url?(url) && !url.start_with?("blob:")
  end

  def image_story_url?(url)
    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png") || url.include?(".webp")
  end

  def likely_avatar?(src)
    src.include?("s150x150") || src.include?("/t51.2885-19/")
  end

  def current_story_owner(page)
    selectors = [
      'a[href^="/"]',
      'header a[href^="/"]'
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
end