# frozen_string_literal: true
# encoding: UTF-8

require "yaml"
require "json"
require "fileutils"

ROOT = "translations"
OUT  = "website/_data/auto_progress.yml"

# --- helpers --------------------------------------------------------

def sh(cmd)
  out = `#{cmd}`
  return "" unless $?.success?
  out
end

def read_json_bom_safe(path)
  return nil unless File.file?(path)
  JSON.parse(File.read(path, mode: "r:bom|utf-8"))
rescue JSON::ParserError => e
  warn "JSON parse error: #{path} (#{e.message})"
  nil
end

# ネストを "a.b[0].c" にフラット化し、文字列の葉だけ抽出
def flatten_leaf_strings(obj, prefix = nil, out = {})
  case obj
  when Hash
    obj.each do |k, v|
      key = prefix ? "#{prefix}.#{k}" : k.to_s
      flatten_leaf_strings(v, key, out)
    end
  when Array
    obj.each_with_index do |v, i|
      key = prefix ? "#{prefix}[#{i}]" : "[#{i}]"
      flatten_leaf_strings(v, key, out)
    end
  else
    out[prefix] = obj if obj.is_a?(String)
  end
  out
end

def calc_progress(slug)
  i18n = File.join(ROOT, slug, "i18n")
  def_path = File.join(i18n, "default.json")
  ja_path  = File.join(i18n, "ja.json")

  def_json = read_json_bom_safe(def_path)
  ja_json  = read_json_bom_safe(ja_path)
  raise "Invalid JSON for #{slug}" unless def_json && ja_json

  flat_def = flatten_leaf_strings(def_json)
  flat_ja  = flatten_leaf_strings(ja_json)

  total = flat_def.size
  untranslated = 0
  flat_def.each do |k, vdef|
    vja = flat_ja[k]
    untranslated += 1 if vja.nil? || vja == vdef
  end

  done = total - untranslated
  pct  = (total.zero? ? 0.0 : (done.to_f * 100.0 / total)).round(1)
  { "pct" => pct, "done" => done, "total" => total }
end

def load_existing
  return { "mods" => {} } unless File.file?(OUT)
  data = YAML.load_file(OUT)
  data.is_a?(Hash) ? data : { "mods" => {} }
rescue
  { "mods" => {} } # 壊れていたら空から
end

# --- staged diff から対象 slug を抽出 -------------------------------

# 形式例: "M\ttranslations/bear-family/i18n/ja.json\nA\ttranslations/eli-and-dylan/i18n/default.json\n..."
diff = sh(%q{git diff --cached --name-status --diff-filter=ACMRD})
lines = diff.split("\n")

changed_slugs = []
deleted_slugs = []

lines.each do |line|
  status, path = line.split("\t", 2)
  next unless path
  next unless path.match?(%r{\Atranslations/[^/]+/i18n/(default|ja)\.json\z})

  # slug = translations/<slug>/...
  slug = path.split("/")[1].downcase

  case status
  when "A", "C", "M"
    changed_slugs << slug
  when "R"
    # R<score>\told\tnew
    _, oldp, newp = line.split("\t", 3)
    if oldp&.match(%r{\Atranslations/[^/]+/i18n/(default|ja)\.json\z})
      old_slug = oldp.split("/")[1].downcase
      deleted_slugs << old_slug
    end
    if newp&.match(%r{\Atranslations/[^/]+/i18n/(default|ja)\.json\z})
      new_slug = newp.split("/")[1].downcase
      changed_slugs << new_slug
    end
  when "D"
    deleted_slugs << slug
  end
end

changed_slugs.uniq!
deleted_slugs.uniq!

if changed_slugs.empty? && deleted_slugs.empty?
  puts "No target slugs. Nothing to do."
  exit 0
end

# --- 既存読み込み → 差分反映 → 書き出し -----------------------------

data = load_existing
mods = (data["mods"].is_a?(Hash) ? data["mods"] : {})

# 更新・追加
changed_slugs.each do |slug|
  mods[slug] = calc_progress(slug) # 失敗時は例外→フックで中断
end

# 削除
deleted_slugs.each { |slug| mods.delete(slug) }

# 安定化（slug昇順）。YAML.dump の sort_keys を併用して確実に固定化
mods_sorted = mods.keys.sort.each_with_object({}) { |k, h| h[k] = mods[k] }

FileUtils.mkdir_p(File.dirname(OUT))
yaml = YAML.dump({ "mods" => mods_sorted }, sort_keys: true, line_width: -1)
File.binwrite(OUT, yaml)

puts "Generated #{OUT} (updated: #{changed_slugs.size}, deleted: #{deleted_slugs.size}, total_slugs: #{mods_sorted.size})"
