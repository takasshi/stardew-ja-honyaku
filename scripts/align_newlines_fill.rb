#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

# === コメント許容（末尾カンマは不許容）の読み込み ===
# 文字列リテラル内は壊さず、行コメント // とブロックコメント /* */ を除去してから JSON.parse。
def read_json_relaxed(path)
  raw = File.read(path, mode: "r:bom|utf-8")

  s = +""
  in_str = false
  esc = false
  in_line = false
  in_block = false
  i = 0

  while i < raw.length
    ch = raw[i]
    nx = (i + 1 < raw.length) ? raw[i + 1] : nil

    if in_line
      if ch == "\n"
        in_line = false
        s << ch
      end
      i += 1
      next
    elsif in_block
      if ch == "*" && nx == "/"
        in_block = false
        i += 2
      else
        s << ch if ch == "\n" # 行数合わせ
        i += 1
      end
      next
    elsif in_str
      s << ch
      if esc
        esc = false
      elsif ch == "\\"
        esc = true
      elsif ch == "\""
        in_str = false
      end
      i += 1
      next
    else
      if ch == "\""
        in_str = true
        s << ch
        i += 1
        next
      end
      if ch == "/" && nx == "/"
        in_line = true
        i += 2
        next
      end
      if ch == "/" && nx == "*"
        in_block = true
        i += 2
        next
      end
      s << ch
      i += 1
    end
  end

  JSON.parse(s) # 末尾カンマがあればここで ParserError
end

def write_json(path, obj)
  File.write(path, JSON.pretty_generate(obj) + "\n")
end

# 改行位置抽出（値文字列内の \n のインデックス）
def newline_indices(str)
  idxs = []
  str.each_char.with_index { |ch, i| idxs << i if ch == "\n" }
  idxs
end

def indices_to_ratios(indices, total_len)
  return [] if total_len <= 0
  indices.reject { |i| i >= total_len }.map { |i| i.to_f / total_len }
end

SAFE_AFTER = /[。．！？!?…]|[」』）】]/.freeze
SAFE_SEP   = /[、，・,\s]/.freeze

# 目標位置近傍で“自然な改行点”にスナップ
def snap_to_safe_break(s, target_idx, window:)
  target_idx = [[target_idx, 0].max, s.length].min

  (target_idx..[target_idx + window, s.length - 1].min).each { |i| return i + 1 if SAFE_AFTER.match?(s[i]) }
  ([target_idx - window, 0].max..target_idx).to_a.reverse.each { |i| return i + 1 if SAFE_AFTER.match?(s[i]) }
  (target_idx..[target_idx + window, s.length - 1].min).each { |i| return i + 1 if SAFE_SEP.match?(s[i]) }
  ([target_idx - window, 0].max..target_idx).to_a.reverse.each { |i| return i + 1 if SAFE_SEP.match?(s[i]) }

  target_idx
end

# 指定位置に \n を挿入（インデックス昇順前提）
def insert_newlines(s, positions)
  return s if positions.empty?
  out = +""
  pos = positions.sort
  j = 0
  s.each_char.with_index do |ch, i|
    if j < pos.length && i == pos[j]
      out << "\n"
      j += 1
    end
    out << ch
  end
  while j < pos.length && pos[j] >= s.length
    out << "\n"
    j += 1
  end
  out
end

# 原文の改行位置（比率）→ 翻訳の近傍安全点へ不足分のみ挿入
def align_text(src_str, jp_str, window:)
  return jp_str unless src_str.is_a?(String) && jp_str.is_a?(String)

  src_breaks = newline_indices(src_str)
  jp_breaks  = newline_indices(jp_str)
  return jp_str if jp_breaks.length >= src_breaks.length # 既に十分

  ratios    = indices_to_ratios(src_breaks, src_str.length)
  tentative = ratios.map { |r| (r * jp_str.length).round }

  snapped = []
  last = -1
  tentative.each do |ti|
    pos = snap_to_safe_break(jp_str, ti, window: window)
    pos = [pos, last + 1].max
    pos = [pos, jp_str.length].min
    snapped << pos
    last = pos
  end

  existing = jp_breaks.to_h { |i| [i, true] }
  final_positions = snapped.reject { |p| existing[p] }

  insert_newlines(jp_str, final_positions)
end

def process(src_h, jp_h, window:, ignore_regex:, fill_missing:)
  # 無視パターンを適用したキー集合
  src_keys = ignore_regex ? src_h.keys.reject { |k| k =~ ignore_regex } : src_h.keys
  jp_keys  = ignore_regex ? jp_h.keys.reject  { |k| k =~ ignore_regex } : jp_h.keys

  missing = src_keys - jp_keys
  extra   = jp_keys  - src_keys

  # 欠けキーの補完
  filled = jp_h.dup
  filled_count = 0
  missing.each do |k|
    src_val = src_h[k]
    next unless src_val.is_a?(String) # 非文字列は放置
    filled[k] =
      case fill_missing
      when "copy"  then src_val.dup
      else              ""           # empty（既定）
      end
    filled_count += 1
  end

  # 余分キーはエラー停止（安全第一）
  unless extra.empty?
    $stderr.puts "⛔ Extra keys exist in JA (not in SRC):"
    $stderr.puts "   #{extra.join(', ')}"
    $stderr.puts "   Remove them or add --ignore REGEX to exclude."
    exit 1
  end

  # 改行位置の整列（不足分のみ）
  fixed = filled.dup
  changed = []
  src_h.each do |k, v|
    next if ignore_regex && k =~ ignore_regex
    next unless v.is_a?(String) && fixed.key?(k) && fixed[k].is_a?(String)
    before = fixed[k]
    after  = align_text(v, before, window: window)
    if after != before
      fixed[k] = after
      changed << k
    end
  end

  [fixed, changed, filled_count, missing, extra]
end

# ===== CLI =====
opts = { in_place: false, window: 30, ignore_regex: nil, fill_missing: "empty" }

OptionParser.new do |o|
  o.banner = "Usage: ruby align_newlines_fill.rb SRC_JSON JA_JSON [--in-place] [--window N] [--ignore REGEX] [--fill-missing=empty|copy]"
  o.on("--in-place", "Overwrite JA_JSON in place") { opts[:in_place] = true }
  o.on("--window N", Integer, "Search window for snapping (default: 30)") { |n| opts[:window] = n }
  o.on("--ignore REGEX", "Ignore keys matching REGEX (e.g., '^(_|//)')") { |r| opts[:ignore_regex] = Regexp.new(r) }
  o.on("--fill-missing=MODE", "Fill missing keys: empty (default) or copy") do |m|
    m = m.to_s.strip.downcase
    abort "Invalid --fill-missing (use empty|copy)" unless %w[empty copy].include?(m)
    opts[:fill_missing] = m
  end
end.parse!

src_path, ja_path = ARGV
abort "Need SRC_JSON and JA_JSON" unless src_path && ja_path

# 読み込み（コメント許容・defaultは読み取り専用）
src = read_json_relaxed(src_path)
ja  = read_json_relaxed(ja_path)

fixed, changed_keys, filled_count, missing_keys, extra_keys =
  process(src, ja, window: opts[:window], ignore_regex: opts[:ignore_regex], fill_missing: opts[:fill_missing])

if opts[:in_place]
  write_json(ja_path, fixed)
  puts "✅ Done."
  puts "   Filled missing keys: #{filled_count} (mode=#{opts[:fill_missing]})"
  puts "   Newline-aligned keys: #{changed_keys.length}"
  puts "   (Filled: #{missing_keys.join(', ')})" unless missing_keys.empty?
else
  puts JSON.pretty_generate(fixed)
end
