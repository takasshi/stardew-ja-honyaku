# scripts/update_changelog.rb
require "yaml"
require "time"
require "fileutils"

def sh(cmd, default: nil)
  out = `#{cmd}`
  return default if !$?.success? && !default.nil?
  raise "Command failed: #{cmd}" unless $?.success?
  out.strip
end

EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# === BEFORE / SHA の決定（CIでもローカルでも安全） ===
IS_CI = (ENV["GITHUB_ACTIONS"] == "true")
ACTOR = (ENV["ACTOR"] || "local")

if IS_CI
  BEFORE = if ENV["BEFORE"].to_s.empty?
             sh("git rev-parse HEAD~1", default: EMPTY_TREE)
           else
             ENV["BEFORE"]
           end
  SHA   = (ENV["SHA"].to_s.empty? ? sh("git rev-parse HEAD") : ENV["SHA"])
  SHORT = SHA[0, 7]

  # BEFORE が履歴に無い（rebase等）→ 空ツリーにフォールバック（CIのみ検査）
  unless system("git cat-file -e #{BEFORE}^{commit} > /dev/null 2>&1")
    warn "WARN: BEFORE #{BEFORE} not found; fallback to EMPTY_TREE"
    Object.send(:remove_const, :BEFORE)
    BEFORE = EMPTY_TREE
  end
else
  # pre-commit 中はコミット未確定なので仮IDを使う
  BEFORE = nil
  SHA    = "STAGED"
  SHORT  = "staged"
end

DATE  = Time.now.getlocal("+09:00").strftime("%Y-%m-%d") # JST表記
SHORT = SHA[0, 7]

# === 変更抽出 ===
changed =
  if IS_CI
    `git diff --name-only #{BEFORE} #{SHA}`.split("\n")
  else
    # pre-commit 時はステージ済みファイルだけを見る
    `git diff --name-only --cached`.split("\n")
  end
changed.select! { |p| p.start_with?("translations/") && p.end_with?("/i18n/ja.json") }
exit 0 if changed.empty?

items = changed.map do |path|
  slug = File.basename(File.dirname(File.dirname(path))).downcase
  { "slug" => slug, "path" => File.join("translations", slug, "i18n", "ja.json") }
end

# === YAML 読込・更新 ===
out_file = File.join("website", "_data", "auto_changelog.yml")
existing =
  if File.exist?(out_file)
    loaded = YAML.load_file(out_file)
    loaded.is_a?(Array) ? loaded : []
  else
    []
  end

if (entry = existing.find { |e| e["sha"] == SHORT })
  entry["items"] ||= []
  existed = entry["items"].map { |i| i["slug"] }
  entry["items"].concat(items.reject { |i| existed.include?(i["slug"]) })
  entry["date"] = DATE
  entry["by"]   = ACTOR
else
  existing.unshift({
    "date"  => DATE,
    "sha"   => SHORT,
    "by"    => ACTOR,
    "items" => items
  })
end

def write_if_changed(path, content)
  return false if File.exist?(path) && File.read(path) == content
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
  true
end

if write_if_changed(out_file, existing.to_yaml)
  puts "Updated #{out_file} (sha #{SHORT}, +#{items.size})"
end
