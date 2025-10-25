# scripts/generate_mod_data.rb
# frozen_string_literal: true
# encoding: UTF-8

require "yaml"
require "json"
require "digest"
require "fileutils"

OUT  = "website/_data/auto_mods.yml"
mods = {}

Dir.glob(File.join("translations", "*", "i18n", "ja.json")).sort.each do |path|
  # translations/<slug>/i18n/ja.json → <slug>（小文字統一）
  slug = File.basename(File.dirname(File.dirname(path))).downcase

  stat     = File.stat(path)
  bytes    = stat.size
  size_kb  = (bytes.to_f / 1024).round(1)           # 小数1桁に固定
  updated  = stat.mtime.utc.strftime("%Y-%m-%d")    # UTC・日付のみ固定
  sha8     = Digest::SHA256.file(path).hexdigest[0, 8]

  # JSON のキー数（壊れてても落ちない）
  keys_count = begin
    json = JSON.parse(File.read(path, mode: "r:bom|utf-8"))
    json.is_a?(Hash) ? json.keys.size : 0
  rescue
    0
  end

  # Windowsでも常に / 区切りに統一
  rel_path = ["translations", slug, "i18n", "ja.json"].join("/")

  mods[slug] = {
    "slug"       => slug,
    "path"       => rel_path,   # 先頭スラ無し（Liquid の | relative_url 前提）
    "updated"    => updated,
    "size_kb"    => size_kb,
    "sha256_8"   => sha8,
    "keys_count" => keys_count
  }
end

# トップレベルも slug の昇順で安定化
mods_sorted = mods.keys.sort.each_with_object({}) { |k, h| h[k] = mods[k] }

FileUtils.mkdir_p(File.dirname(OUT))

yaml = YAML.dump(mods_sorted, sort_keys: true, line_width: -1) # 重要：キー順固定・折返し無効
File.binwrite(OUT, yaml)                                       # 重要：改行差吸収

puts "Generated #{OUT} (#{mods.size} mods)"
