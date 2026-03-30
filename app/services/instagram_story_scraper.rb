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
        media_urls = []
        seen_media = Set.new

        page.on("response", ->(response) do
          begin
            url = response.url

            if story_media_url?(url) && !seen_media.include?(url)
              seen_media << url
              media_urls << {
                url: url,
                content_type: response.header_value("content-type")
              }
              puts "MEDIA RESPONSE: #{url}"
            end
          rescue => e
            puts "Response capture error: #{e.message}"
          end
        end)

        page.goto(story_url, waitUntil: "domcontentloaded", timeout: 30_000)
        page.wait_for_timeout(4000)

        click_story_entry_prompt(page)
        page.wait_for_timeout(4000)

        items = collect_story_frames(page, media_urls)

        {
          active: items.any?,
          source: profile_username,
          fetched_at: Time.current.iso8601,
          expires_at: Time.current.end_of_day.iso8601,
          items: items
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

  def collect_story_frames(page, media_urls)
    items = []
    seen_urls = Set.new

    MAX_STORIES.times do |index|
      page.wait_for_timeout(2500)

      current_item = extract_current_frame(page, media_urls)
      if current_item && !seen_urls.include?(current_item[:media_url])
        seen_urls << current_item[:media_url]
        current_item[:order] = items.length + 1
        items << current_item
        puts "Captured frame #{items.length}: #{current_item[:type]} #{current_item[:media_url]}"
      else
        puts "No new frame captured at step #{index + 1}"
      end

      break unless click_next_story(page)
    end

    items
  end

  def extract_current_frame(page, media_urls)
    latest_media = media_urls.reverse.find { |entry| usable_story_media?(entry[:url]) }

    if latest_media
      content_type = latest_media[:content_type].to_s

      if content_type.include?("video") || latest_media[:url].include?(".mp4")
        return { type: "video", media_url: latest_media[:url] }
      end

      if content_type.include?("image") || image_story_url?(latest_media[:url])
        return { type: "image", media_url: latest_media[:url] }
      end
    end

    extract_current_frame_from_dom(page)
  end

  def extract_current_frame_from_dom(page)
    video_nodes = page.locator("video")
    if video_nodes.count > 0
      poster = video_nodes.first.get_attribute("poster")
      return { type: "image", media_url: poster } if poster.present?
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

  def click_next_story(page)
    selectors = [
      'svg[aria-label="Next"]',
      'button[aria-label="Next"]',
      'div[role="button"][aria-label="Next"]'
    ]

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
      return true
    rescue
      false
    end
  end

  def story_media_url?(url)
    return false if url.blank?
    return false unless url.include?("fbcdn.net") || url.include?("cdninstagram.com") || url.include?("instagram")
    return false if likely_avatar?(url)

    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png") || url.include?(".mp4") || url.include?("bytestart")
  end

  def usable_story_media?(url)
    story_media_url?(url) && !url.start_with?("blob:")
  end

  def image_story_url?(url)
    url.include?(".jpg") || url.include?(".jpeg") || url.include?(".png")
  end

  def likely_avatar?(src)
    src.include?("s150x150") || src.include?("/t51.2885-19/")
  end
end
