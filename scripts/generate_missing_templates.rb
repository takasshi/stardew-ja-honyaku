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
# --- slug（重要） ---
slug: #{slug} # 小文字で書く（基本的には自動生成）

# --- 基本情報 ---
title: "#{slug} 翻訳ファイル"
category: "others" # expansion、items、ui、others
status: hidden # active、retired、upcoming、hidden（自動生成時）

original_name: "" # 翻訳元MODの名前

# --- メタ情報（auto_mods.ymlで出せないやつ） ---
mod_ver: "MODのバージョン" # 無記入OK。""は消す。
release_date: "YYYY-MM-DD" # YYYY-MM-DD

source:
  - name:  # 空欄の場合Nexus Modsがデフォルト

links:
    url: "https://www.nexusmods.com/stardewvalley/mods/35474"

# --- 概要・紹介 ---
summary: | # 一覧ページ・個別ページ上部のキャッチコピー
    キャッチコピー

note: "～～なMODです。" # 一覧ページの青いブロック（無記入OK）

description: | # 前提MODなど。
  ◯◯です。前提MOD：Mail Framework Mod

# --- アイキャッチ画像 ---
hero:
  image:  # 無記入OK
  caption:  # 無記入OK

# --- 詳細説明（長文セクション） ---
features: # MODのおすすめポイントを箇条書きで書く。
  - "◯◯なところがおすすめ！"

install-warning: | # MOD内の注意書き。翻訳についての注意書きではない。（無記入OK）
  ⚠ 軽度な薬物依存描写があります。

policy: | # 翻訳のクセなど。
  - ◯◯なクセがあります。

install-notes: | # フォルダ名が特殊な場合記入（無記入OK）

# --- 更新履歴 ---
changelog:
  - version: "v1.0.1 -translation"
    date: "2025-10-19"  # auto_mods.yml★
    body: |
      - 公開。
  YML

  ensure_file(md, <<~MD)
    ---
    layout: mod-detail
    slug: #{slug}
    published: true
    ---
  MD
end
