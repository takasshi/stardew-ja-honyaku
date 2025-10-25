# scripts/generate_missing_templates.rb
require "fileutils"

BASE_SITE_DIR = "website" # Jekyll ルート

def slugs
  Dir.glob(File.join("translations", "*", "i18n", "ja.json"))
     .map { |p| File.basename(File.dirname(File.dirname(p))).downcase } # 小文字統一
     .uniq
     .sort
end

def ensure_file(path, content)
  return if File.exist?(path)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
  puts "created: #{path}"
end

slugs.each do |slug|
  yml = File.join(BASE_SITE_DIR, "_data", "mods", "#{slug}.yml")
  md  = File.join(BASE_SITE_DIR, "pages", "mods", "#{slug}.md")

  ensure_file(yml, <<~YML)
    slug: #{slug}
    title: ""
    category: ""
    status: "active"
    summary: ""
    install-notes: ""
    install-warning: ""
    features: []
    links:
      url: ""
  YML

  ensure_file(md, <<~MD)
    ---
    layout: mod-detail
    slug: #{slug}
    published: true
    ---
  MD
end
