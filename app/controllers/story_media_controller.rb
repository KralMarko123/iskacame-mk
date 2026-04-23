class StoryMediaController < ApplicationController
  def show
    filename = File.basename(params[:filename].to_s)
    path = Rails.root.join("public", "story_cache", filename)

    return head :not_found unless File.file?(path)

    send_data(
      File.binread(path),
      filename: filename,
      disposition: "inline",
      type: content_type_for(filename)
    )
  end

  private

  def content_type_for(filename)
    case File.extname(filename).downcase
    when ".png"
      "image/png"
    when ".jpg", ".jpeg"
      "image/jpeg"
    when ".webp"
      "image/webp"
    when ".mp4"
      "video/mp4"
    else
      "application/octet-stream"
    end
  end
end
