class StoryCacheCleanup
  OUTPUT_DIR = Rails.root.join("public", "story_cache")

  def call
    return unless Dir.exist?(OUTPUT_DIR)

    Dir.glob(OUTPUT_DIR.join("*")).each do |path|
      next unless File.file?(path)
      next if File.mtime(path) > 1.day.ago

      File.delete(path)
    rescue => e
      Rails.logger.warn("Could not delete #{path}: #{e.message}")
    end
  end
end