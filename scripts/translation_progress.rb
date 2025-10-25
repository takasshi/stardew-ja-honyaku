# scripts/generate_progress_data.rb
# frozen_string_literal: true
# encoding: UTF-8

require "yaml"
require "json"
require "time"
require "fileutils"

OUT = "website/_data/auto_progress.yml"

# -------- Helpers (auto_mods と同等の堅牢性／再現性) --------

def read_json(path)
  # UTF-8+BOM 対応、失敗時は nil
  JSON.parse(File.read(path, mode: "r:bom|utf-8"))
rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
  nil
end

def flatten(obj, prefix = "", out = {})
  case obj
  when Hash
    obj.each { |k, v| flatten(v, prefix.empty? ? k.to_s : "#{prefix}.#{k}", out) }
  when Array
    obj.each_with_index { |v, i| flatten(v, "#{prefix}[#{i}]", out) }
  else
    out[prefix] = obj.nil? ? "" : obj.to_s
  end
  out
end

def normalize(s)
  s = (s || "").to_s
  s = s.gsub(/\r\n?/, "\n")        # 改行統一
  s = s.gsub(/[ \t\u3000]+/, " ")  # 全角含む連続空白→半角1つ
  s.strip
end

def looks_japanese?(s)
  !!(s =~ /[ぁ-んァ-ン一-龯々〆ヵヶ]/)
end

ASCII_PUNCT_RE = /\A[0-9A-Za-z\s\.\,\!\?\%\-\:\;\(\)\'\"\+\=\*&\/\\_@\#\$\^~\|\[\]\{\}]+\z/
def ascii_punct_only?(s) = !!(s =~ ASCII_PUNCT_RE)

# -------- Collect & Compute --------

mods = {}

Dir.glob(File.join("translations", "*", "i18n", "ja.json")).sort.each do |ja_path|
  # Windowsでも / 区切りに揃える
  ja_path = ja_path.tr("\\", "/")
  slug    = File.basename(File.dirname(File.dirname(ja_path))).downcase
  def_path = File.join(File.dirname(ja_path), "default.json").tr("\\", "/")

  # 原文(default.json)が無い場合はスキップ（比較できないため）
  next unless File.file?(def_path)

  def_json = read_json(def_path)
  ja_json  = read_json(ja_path)
  next if def_json.nil? || ja_json.nil?

  flat_def = flatten(def_json)
  flat_ja  = flatten(ja_json)

  total = flat_def.size
  done  = 0

  flat_def.each do |key, def_val|
    def_norm = normalize(def_val)
    ja_norm  = normalize(flat_ja.key?(key) ? flat_ja[key] : "")

    translated =
      if ja_norm.empty?
        false
      elsif ja_norm == def_norm
        false
      else
        if ascii_punct_only?(ja_norm) && ascii_punct_only?(def_norm)
          a = ja_norm.gsub(/\s+/, "").downcase
          b = def_norm.gsub(/\s+/, "").downcase
          a != b
        else
          true
        end
      end

    translated ||= looks_japanese?(ja_norm)
    done += 1 if translated
  end

  pct = total.zero? ? 100.0 : (done * 100.0 / total)

  mods[slug] = {
    "pct"   => pct.round(1),
    "done"  => done,
    "total" => total,
  }
end

# -------- Dump (順序安定・出力安定) --------

data = {
  "generated_at" => Time.now.utc.iso8601,
  "mods" => mods.keys.sort.each_with_object({}) { |k, h| h[k] = mods[k] }
}

FileUtils.mkdir_p(File.dirname(OUT))
yaml = YAML.dump(data, sort_keys: true, line_width: -1) # キー順固定・折り返し無効
File.binwrite(OUT, yaml)

puts "Generated #{OUT} (#{mods.size} mods)"
