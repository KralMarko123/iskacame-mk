require "json"
require "time"

class InstagramStoryScraper
  PROFILE = ENV.fetch("INSTAGRAM_TARGET_PROFILE")

  def call
    playwright_cli = ENV["PLAYWRIGHT_CLI_EXECUTABLE_PATH"]

    Playwright.create(playwright_cli_executable_path: playwright_cli) do |playwright|
      browser = playwright.chromium.launch(headless: true)
      context = browser.new_context
      page = context.new_page

      begin
        page.goto("https://www.instagram.com/#{PROFILE}/", wait_until: "domcontentloaded", timeout: 30_000)

        dismiss_cookie_banner_if_present(page)
        open_story_if_present(page)

        items = extract_story_items(page)

        {
          active: items.any?,
          source: PROFILE,
          fetched_at: Time.current.iso8601,
          expires_at: Time.current.end_of_day.iso8601,
          items: items
        }
      ensure
        browser.close
      end
    end
  end

  private

  def dismiss_cookie_banner_if_present(page)
    buttons = [
      "Allow all cookies",
      "Allow essential and optional cookies",
      "Only allow essential cookies"
    ]

    buttons.each do |label|
      locator = page.locator("text=#{label}")
      if locator.count > 0
        locator.first.click
        break
      end
    rescue
      next
    end
  end

  def open_story_if_present(page)
    possible_selectors = [
      "canvas",
      "header a",
      "img[alt*='profile picture' i]"
    ]

    possible_selectors.each do |selector|
      locator = page.locator(selector)
      next unless locator.count > 0

      locator.first.click
      sleep 2
      return
    rescue
      next
    end
  end

  def extract_story_items(page)
    items = []

    image_nodes = page.locator("img")
    image_count = image_nodes.count

    (0...image_count).each do |i|
      src = image_nodes.nth(i).get_attribute("src")
      next if src.blank?
      next unless src.include?("instagram")
      next if likely_avatar?(src)

      items << {
        type: "image",
        media_url: src,
        order: items.length + 1
      }
    rescue
      next
    end

    video_nodes = page.locator("video")
    video_count = video_nodes.count

    (0...video_count).each do |i|
      src = video_nodes.nth(i).get_attribute("src")
      next if src.blank?

      items << {
        type: "video",
        media_url: src,
        order: items.length + 1
      }
    rescue
      next
    end

    items.uniq { |item| [item[:type], item[:media_url]] }
  end

  def likely_avatar?(src)
    src.include?("s150x150") || src.include?("profile")
  end
end