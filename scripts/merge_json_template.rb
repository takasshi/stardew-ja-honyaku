#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

# ========== コメント許容（//, ##, /* */）で読み込む：値抽出専用 ==========
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
  if ch == "\n"
    in_line = false
    s << ch   # 改行だけ保持（行番号合わせ）
  end
  i += 1
  next
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
      if ch == "#" && nx == "#"
        in_line = true
        i += 2
        next
      end
      s << ch
      i += 1
    end
  end

  JSON.parse(s) # 末尾カンマは不許容
end

# JSON 文字列用のエスケープ
def json_escape(str)
  str.to_s.gsub(/["\\\b\f\n\r\t]/) do |m|
    { '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\f" => "\\f",
      "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }[m]
  end
end

# JSON の "..." を生テキストから安全に読み飛ばす（閉じダブルクオートの位置を返す）
def scan_string_end(src, i)
  # i は開きの `" ` を指している前提
  j = i + 1
  esc = false
  while j < src.length
    ch = src[j]
    if esc
      esc = false
    elsif ch == "\\"
      esc = true
    elsif ch == "\""
      return j
    end
    j += 1
  end
  nil
end

# JSON 文字列の中身を最小限アンエスケープ（キー名判定用）
def unescape_json_string(raw)
  s = +""
  i = 0
  while i < raw.length
    ch = raw[i]
    if ch != "\\"
      s << ch
      i += 1
      next
    end
    nx = raw[i + 1]
    case nx
    when "\"", "\\", "/"
      s << nx
      i += 2
    when "b" then s << "\b"; i += 2
    when "f" then s << "\f"; i += 2
    when "n" then s << "\n"; i += 2
    when "r" then s << "\r"; i += 2
    when "t" then s << "\t"; i += 2
    when "u"
      hex = raw[i + 2, 4]
      if hex && hex.match?(/\A[0-9A-Fa-f]{4}\z/)
        s << hex.to_i(16).chr(Encoding::UTF_8)
        i += 6
      else
        s << "\\u"; i += 2
      end
    else
      # 不明なエスケープはそのまま
      s << "\\" << nx
      i += 2
    end
  end
  s
end

# 次の非空白文字のインデックス
def next_nonspace(src, idx)
  j = idx
  while j < src.length && src[j] =~ /[ \t\r\n]/
    j += 1
  end
  j
end

# default テンプレートをなぞり、値の "..." だけをスキップして ja_map の値を差し込む
def merge_by_template(default_path, ja_map, out_path)
  src = File.read(default_path, mode: "r:bom|utf-8")
  File.open(out_path, "w:utf-8") do |out|
    i = 0
    in_str = false
    esc = false
    in_line = false
    in_block = false
    depth = 0

    current_key = nil
    expect_value_for_key = false

    while i < src.length
      ch = src[i]
      nx = src[i + 1]

      # コメント状態
      if in_line
        out << ch
        if ch == "\n"
          in_line = false
        end
        i += 1
        next
      elsif in_block
        out << ch
        if ch == "*" && nx == "/"
          out << nx
          i += 2
          in_block = false
        else
          i += 1
        end
        next
      end

      # 文字列状態（そのまま写す）
      if in_str
        out << ch
        if esc
          esc = false
        elsif ch == "\\"
          esc = true
        elsif ch == "\""
          in_str = false
        end
        i += 1
        next
      end

      # ここから「文字列外」の通常状態
      # コメント開始検出（default側コメントはそのまま出力）
      if ch == "/" && nx == "/"
        out << ch << nx
        in_line = true
        i += 2
        next
      elsif ch == "/" && nx == "*"
        out << ch << nx
        in_block = true
        i += 2
        next
      elsif ch == "#" && nx == "#"
        out << ch << nx
        in_line = true
        i += 2
        next
      end

      # 構造記号の追跡（深さ）
      if ch == "{"
        depth += 1
      elsif ch == "}"
        depth -= 1
        # オブジェクト終端でキー/値期待をリセット
        current_key = nil
        expect_value_for_key = false
      elsif ch == ","
        # ペア終了
        current_key = nil
        expect_value_for_key = false
      end

      # コロンで「次は値」を期待
      if ch == ":"
        out << ch
        expect_value_for_key = !current_key.nil?
        i += 1
        next
      end

      # ダブルクオートに遭遇：キー or 値 のどちらか
      if ch == "\""
        j = scan_string_end(src, i)
        # 壊れたJSONは別スクリプトで検証する想定
        j ||= src.length - 1

        # 直後が : なら「キー」
        after = next_nonspace(src, j + 1)
        if after < src.length && src[after] == ":"
          # キーはそのまま出力して覚える
          out << src[i..j]
          # キー文字列をアンエスケープして取得
          raw_key = src[i + 1...j]
          current_key = unescape_json_string(raw_key)
          # 次に : を通過したら値を置換対象にする（ここではまだ書かない）
          i = j + 1
          next
        else
          # 値の文字列
          if expect_value_for_key && current_key && ja_map.key?(current_key)
            # 元の値文字列はスキップして、日本語の値を差し込む
            val = ja_map[current_key]
            out << "\"" << json_escape(val) << "\""
            # 置換完了。次の , または } まで current_key は保持しておく必要はない
            expect_value_for_key = false
            current_key = nil
            i = j + 1
            next
          else
            # 置換対象でなければそのまま出力
            out << src[i..j]
            i = j + 1
            next
          end
        end
      end

      # 通常の1文字出力
      out << ch
      # 文字列開始の管理
      in_str = true if ch == "\""
      i += 1
    end
  end
end

# ===== CLI =====
opts = { in_place: false }
OptionParser.new do |o|
  o.banner = "Usage: ruby merge_json_template.rb DEFAULT_JSON JA_JSON [--in-place]"
  o.on("--in-place", "Overwrite JA_JSON in place") { opts[:in_place] = true }
end.parse!

default_path, ja_path = ARGV
abort "Need DEFAULT_JSON and JA_JSON" unless default_path && ja_path

# ja の値（コメント無視で読み取り）
ja_map = read_json_relaxed(ja_path)

# 出力先（テストは out.json、本番は ja.json を上書き）
out_path = opts[:in_place] ? ja_path : File.expand_path("out.json", Dir.pwd)
merge_by_template(default_path, ja_map, out_path)

puts "✅ Done. Wrote to #{out_path}"
