require "playwright"
require "fileutils"

class InstagramLoginSession
  LOGIN_URL = "https://www.instagram.com/accounts/login/"

  def call
    storage_state_path = ENV.fetch("INSTAGRAM_STORAGE_STATE_PATH", "tmp/instagram_auth.json")
    FileUtils.mkdir_p(File.dirname(storage_state_path))

    Playwright.create(
      playwright_cli_executable_path: ENV.fetch("PLAYWRIGHT_CLI_EXECUTABLE_PATH", "npx playwright")
    ) do |playwright|
      browser = playwright.chromium.launch(headless: false)
      context = browser.new_context(ignoreHTTPSErrors: true)
      page = context.new_page

      begin
        page.goto(LOGIN_URL, waitUntil: "domcontentloaded", timeout: 30_000)
        page.wait_for_timeout(5000)

        dismiss_cookie_banner(page)

        page.screenshot(path: "tmp/instagram_login_page.png", fullPage: true)

        puts "TITLE: #{page.title}"
        puts "URL: #{page.url}"

        debug_inputs(page)

        username_input = find_first_visible(page, [
          'input[name="username"]',
          'input[aria-label="Phone number, username, or email"]',
          'input[aria-label="Phone number, username or email"]',
          'input[autocomplete="username"]',
          'input[type="text"]'
        ])

        password_input = find_first_visible(page, [
          'input[name="password"]',
          'input[aria-label="Password"]',
          'input[autocomplete="current-password"]',
          'input[type="password"]'
        ])

        raise "Could not find username input" unless username_input
        raise "Could not find password input" unless password_input

        username_input.fill(ENV.fetch("INSTAGRAM_USERNAME"))
        password_input.fill(ENV.fetch("INSTAGRAM_PASSWORD"))

        submit_button = find_first_visible(page, [
          'button[type="submit"]',
          'button:has-text("Log in")',
          'button:has-text("Log In")',
          'div[role="button"]:has-text("Log in")',
          'div[role="button"]:has-text("Log In")'
        ])

        raise "Could not find login button" unless submit_button

        submit_button.click
        page.wait_for_timeout(8000)

        page.screenshot(path: "tmp/instagram_after_login.png", fullPage: true)

        dismiss_post_login_prompt(page)

        context.storage_state(path: storage_state_path)

        {
          success: true,
          storage_state_path: storage_state_path,
          current_url: page.url
        }
      ensure
        context.close
        browser.close
      end
    end
  end

  private

  def dismiss_cookie_banner(page)
    [
      "Allow all cookies",
      "Only allow essential cookies",
      "Allow essential and optional cookies"
    ].each do |text|
      locator = page.locator("text=#{text}")
      next unless locator.count > 0

      locator.first.click
      page.wait_for_timeout(1500)
      return
    rescue
      next
    end
  end

  def dismiss_post_login_prompt(page)
    [
      "Not Now",
      "Not now",
      "Save info",
      "Save Info"
    ].each do |text|
      locator = page.locator("text=#{text}")
      next unless locator.count > 0

      locator.first.click
      page.wait_for_timeout(1500)
    rescue
      next
    end
  end

  def find_first_visible(page, selectors)
    selectors.each do |selector|
      begin
        locator = page.locator(selector)
        count = locator.count
        puts "Selector #{selector} count: #{count}"
        return locator.first if count > 0
      rescue => e
        puts "Selector error for #{selector}: #{e.message}"
      end
    end

    nil
  end

  def debug_inputs(page)
    inputs = page.locator("input")
    count = inputs.count
    puts "INPUT COUNT: #{count}"

    (0...count).each do |i|
      input = inputs.nth(i)
      puts({
             index: i,
             name: input.get_attribute("name"),
             type: input.get_attribute("type"),
             aria_label: input.get_attribute("aria-label"),
             autocomplete: input.get_attribute("autocomplete"),
             placeholder: input.get_attribute("placeholder")
           }.inspect)
    rescue => e
      puts "Input debug error at #{i}: #{e.message}"
    end
  end
end