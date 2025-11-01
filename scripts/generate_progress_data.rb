#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8
#
# 全MODの翻訳率を強制再計算するスクリプト
# default.json を Git 管理に含めず安全に動作します

require "yaml"
require "json"
require "fileutils"

ROOT = "translations"
OUT  = "website/_data/auto_progress.yml"

# --- JSON読込ユーティリティ --------------------------------------------

def read_json_bom_safe(path)
  return nil unless File.file?(path)
  JSON.parse(File.read(path, mode: "r:bom|utf-8"))
rescue JSON::ParserError => e
  warn "⚠️ JSON parse error: #{path} (#{e.message})"
  nil
end

# --- ネスト構造を a.b[0].c にフラット化 --------------------------------
# （文字列の葉ノードのみ抽出）
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

# --- 翻訳率の計算 --------------------------------------------------------
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

# --- 既存YAMLの読み込み（壊れてたら空から） -----------------------------
def load_existing
  return { "mods" => {} } unless File.file?(OUT)
  data = YAML.load_file(OUT)
  data.is_a?(Hash) ? data : { "mods" => {} }
rescue
  { "mods" => {} }
end

# --- 全MOD列挙＆再計算 ---------------------------------------------------
puts "⚙️ 全MODの翻訳率を再計算中..."
mods = {}

Dir.glob(File.join(ROOT, "*", "i18n", "ja.json")).sort.each do |path|
  slug = File.basename(File.dirname(File.dirname(path))).downcase
  begin
    mods[slug] = calc_progress(slug)
  rescue => e
    warn "❌ #{slug} の計算に失敗しました: #{e.message}"
  end
end

# --- YAMLとして書き出し --------------------------------------------------
mods_sorted = mods.keys.sort.each_with_object({}) { |k, h| h[k] = mods[k] }

FileUtils.mkdir_p(File.dirname(OUT))
yaml = YAML.dump({ "mods" => mods_sorted }, sort_keys: true, line_width: -1)
File.binwrite(OUT, yaml)

puts "✅ 完了: #{OUT} を更新しました（#{mods_sorted.size} 件）"
