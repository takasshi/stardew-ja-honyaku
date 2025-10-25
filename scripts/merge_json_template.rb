#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

# === コメント許容JSONの読み込み（値抽出用） ===
# 文字列内は壊さず、行コメント // や ##、ブロックコメント /* */ を除去してから JSON.parse。
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
    nx = raw[i + 1]
    if in_line
      in_line = false if ch == "\n"
      s << ch
      i += 1
      next
    elsif in_block
      if ch == "*" && nx == "/"
        in_block = false
        i += 2
      else
        s << ch if ch == "\n"
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
      if ch == "#" && nx == "#"
        in_line = true
        i += 2
        next
      end
      s << ch
      i += 1
    end
  end

  JSON.parse(s)
end

# === JSON文字列として安全に値を書き出す ===
def json_escape(str)
  str.to_s.gsub(/["\\\b\f\n\r\t]/) do |m|
    { '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f",
      "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }[m]
  end
end

# === defaultテンプレートの構造をなぞりつつ値を差し替え ===
def merge_by_template(default_path, ja_map, out_path)
  src = File.read(default_path, mode: "r:bom|utf-8")
  out = File.open(out_path, "w:utf-8")

  in_str = false
  esc = false
  key_buf = +""
  val_mode = false
  key = nil

  i = 0
  while i < src.length
    ch = src[i]
    nx = src[i + 1]

    if in_str
      out << ch
      if esc
        esc = false
      elsif ch == "\\"
        esc = true
      elsif ch == "\""
        in_str = false
        if val_mode
          # 値文字列終了 → 差し替え候補
          if key && ja_map.key?(key)
            # 差し替え：直前の値を日本語に置換
            val = ja_map[key]
            esc_val = json_escape(val)
            # 上書き出力：前の " を含めて置換
            out.seek(-(key_buf.length + 2), IO::SEEK_CUR) if key_buf.size > 0
            out << "\"#{esc_val}\""
          end
          key = nil
          val_mode = false
          key_buf.clear
        end
      end
      i += 1
      next
    else
      if ch == "\""
        in_str = true
        out << ch
        # キー取得モード開始
        if !val_mode && key.nil?
          # 次の : までを見てキーと判断
          j = i + 1
          kbuf = +""
          esc2 = false
          while j < src.length
            cj = src[j]
            if esc2
              kbuf << cj
              esc2 = false
            elsif cj == "\\"
              esc2 = true
              kbuf << cj
            elsif cj == "\""
              break
            else
              kbuf << cj
            end
            j += 1
          end
          # 次が : ならキー確定
          tail = src[j..j + 10] || ""
          if tail.include?(":")
            key = kbuf
          end
        else
          # 値モードの文字列開始
          val_mode = true if key
          key_buf.clear
        end
        i += 1
        next
      end
      out << ch
      i += 1
    end
  end

  out.close
end

# ===== CLI =====
opts = { in_place: false }

OptionParser.new do |o|
  o.banner = "Usage: ruby merge_json_template.rb DEFAULT_JSON JA_JSON [--in-place]"
  o.on("--in-place", "Overwrite JA_JSON in place") { opts[:in_place] = true }
end.parse!

default_path, ja_path = ARGV
abort "Need DEFAULT_JSON and JA_JSON" unless default_path && ja_path

ja_map = read_json_relaxed(ja_path)

out_path = opts[:in_place] ? ja_path : "out.json"
merge_by_template(default_path, ja_map, out_path)

puts "✅ Done. Wrote to #{opts[:in_place] ? ja_path : out_path}"
