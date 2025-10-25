# scripts/hook_precommit.rb
# Ruby 3.x 想定（Windows/macOS/Linux で安定動作）
# 生成物（auto_* と website/translations 配下）だけの変更は許可。
# それ以外の差分や “warnings” があればコミットをブロックします。

require "json"
require "yaml"
require "time"
require "open3"
require "fileutils"

# ===== 設定 =====
ALLOWED_GENERATED_FILES = [
  "website/_data/auto_mods.yml",
  "website/_data/auto_changelog.yml",
  "website/_data/auto_progress.yml",
].freeze

ALLOWED_GENERATED_DIRS = [
  "website/translations",  # ディレクトリ配下すべて許可
].freeze

# ===== ユーティリティ =====
def run(cmd)
  out, err, st = Open3.capture3(cmd)
  [out, err, st.success?]
end

def normalize_path(p)
  p.to_s.tr("\\", "/")
end

def staged_paths(glob = nil)
  out, _, _ = run(%{git diff --cached --name-only})
  files = out.split("\n").map { |x| normalize_path(x) }
  files = Dir.glob(glob).map { |x| normalize_path(x) } if files.empty? && glob
  files
end

def snapshot_changes
  unstaged, _, _ = run(%{git diff --name-only})
  staged,   _, _ = run(%{git diff --cached --name-only})
  (unstaged.split("\n") + staged.split("\n"))
    .map { |x| normalize_path(x) }
    .reject(&:empty?).uniq
end

def allowed_generated_path?(path)
  p = normalize_path(path)
  return true if ALLOWED_GENERATED_FILES.include?(p)
  ALLOWED_GENERATED_DIRS.any? { |dir| p == dir || p.start_with?("#{dir}/") }
end

def print_list(prefix, items)
  items.each { |x| puts "#{prefix} #{x}" }
end

# ===== 収集入れ物 =====
warnings = []
notes    = []

# ===== ベースライン差分のスナップショット =====
BASELINE_CHANGES = snapshot_changes

# =============================
# 1) translation スラッグのバリデーション
# =============================
Dir.glob("translations/*/i18n/ja.json").each do |p|
  slug = normalize_path(p).split("/")[1]
  unless slug =~ /\A[a-z0-9\-]+\z/
    warnings << "translations/#{slug}/…: フォルダ名に大文字または不正文字（許可: a-z0-9-）"
  end
end

# =============================
# 1.5) i18n フォルダ存在・ja.json 存在チェック
# =============================
Dir.glob("translations/*").each do |slug_dir|
  next unless File.directory?(slug_dir)
  slug_dir = normalize_path(slug_dir)
  slug     = File.basename(slug_dir)
  i18n_dir = normalize_path(File.join(slug_dir, "i18n"))
  ja_path  = normalize_path(File.join(i18n_dir, "ja.json"))

  unless File.directory?(i18n_dir)
    warnings << "⚠️  #{slug_dir}: i18n フォルダが存在しません。構成を修正してください。"
    next
  end

  unless File.exist?(ja_path)
    warnings << "⚠️  #{slug_dir}: i18n フォルダ内に ja.json が存在しません。翻訳ファイルを追加してください。"
  end
end

# =============================
# 2) i18n フォルダの不要ファイル検出（削除せず警告）
# =============================
Dir.glob("translations/*/i18n").each do |dir|
  next unless File.directory?(dir)
  entries = Dir.children(dir)
  extra = entries.reject { |f| %w[ja.json default.json].include?(f) }
  warnings << "#{normalize_path(dir)}: 不要ファイルを検出（#{extra.join(', ')}）→ 削除せず警告のみ" unless extra.empty?
end

# =============================
# 3) commit-msg での検証案内（pre-commit では実施しない）
# =============================
# pre-commit 時点では COMMIT_EDITMSG が無いのでここではスキップ

# =============================
# 4) テンプレ生成
# =============================
if File.exist?("scripts/generate_missing_templates.rb")
  out, err, ok = run("ruby scripts/generate_missing_templates.rb")
  ok ? (notes << out.strip unless out.strip.empty?) :
       (warnings << "generate_missing_templates.rb 実行エラー:\n#{out}\n#{err}")
else
  notes << "ℹ️  generate_missing_templates.rb は未配置（スキップ）"
end

# =============================
# 5) auto_mods 生成
# =============================
if File.exist?("scripts/generate_mod_data.rb")
  out, err, ok = run("ruby scripts/generate_mod_data.rb")
  ok ? (notes << out.strip unless out.strip.empty?) :
       (warnings << "generate_mod_data.rb 実行エラー:\n#{out}\n#{err}")
else
  notes << "ℹ️  generate_mod_data.rb は未配置（スキップ）"
end

# =============================
# 5.5) auto_progress 生成（翻訳進捗）
# =============================
if File.exist?("scripts/generate_progress_data.rb")
  out, err, ok = run("ruby scripts/generate_progress_data.rb")
  ok ? (notes << out.strip unless out.strip.empty?) :
       (warnings << "generate_progress_data.rb 実行エラー:\n#{out}\n#{err}")
else
  notes << "ℹ️  generate_progress_data.rb は未配置（スキップ）"
end

# =============================
# 6) チェンジログ更新（自動で BEFORE/SHA 推測）
# =============================
if File.exist?("scripts/update_changelog.rb")
  out, err, ok = run("ruby scripts/update_changelog.rb")
  ok ? (notes << out.strip unless out.strip.empty?) :
       (warnings << "update_changelog.rb 実行エラー:\n#{out}\n#{err}")
else
  notes << "ℹ️  update_changelog.rb は未配置（スキップ）"
end

# =============================
# 7) translations → website/translations 同期
# =============================
begin
  src  = "translations"
  dest = "website/translations"
  FileUtils.mkdir_p(dest)
  FileUtils.cp_r("#{src}/.", dest, remove_destination: true)
  notes << "🔁 copied translations → website/translations"
rescue => e
  warnings << "translations コピー中にエラー: #{e.class}: #{e.message}"
end

# =============================
# 8) JSON / YAML 構文チェック
# =============================
json_targets = staged_paths || []
json_targets = json_targets.select { |p| p.end_with?(".json") }
json_targets = Dir.glob("translations/**/i18n/*.json").map { |x| normalize_path(x) } if json_targets.empty?
# ミラー先の JSON は除外
json_targets.reject! { |p| p.start_with?("website/translations/") }

json_targets.each do |path|
  next unless File.file?(path)
  begin
    text = File.read(path, mode: "rb:utf-8")
    JSON.parse(text)
  rescue JSON::ParserError => e
    warnings << "#{path}: JSON 構文エラー → #{e.message}"
  rescue => e
    warnings << "#{path}: JSON 読み込みエラー → #{e.class}: #{e.message}"
  end
end

yaml_targets = staged_paths || []
yaml_targets = yaml_targets.select { |p| p =~ /\.ya?ml$/ }
yaml_targets = Dir.glob("website/_data/**/*.yml").map { |x| normalize_path(x) } if yaml_targets.empty?

yaml_targets.each do |path|
  next unless File.file?(path)
  begin
    YAML.safe_load(File.read(path, mode: "rb:utf-8"), permitted_classes: [], aliases: false)
  rescue Psych::Exception => e
    warnings << "#{path}: YAML 構文エラー → #{e.message}"
  rescue => e
    warnings << "#{path}: YAML 読み込みエラー → #{e.class}: #{e.message}"
  end
end

# =============================
# 9) 翻訳ファイルサイズ（情報ログ）
# =============================
Dir.glob("translations/*/i18n/ja.json").each do |ja|
  slug = normalize_path(ja).split("/")[1]
  ja_kb = (File.size(ja) / 1024.0).round(1) rescue nil
  default = File.join("translations", slug, "i18n", "default.json")
  if File.exist?(default)
    def_kb = (File.size(default) / 1024.0).round(1) rescue nil
    notes << "📦 size #{slug}: ja=#{ja_kb}KB / default=#{def_kb}KB"
  else
    notes << "📦 size #{slug}: ja=#{ja_kb}KB (default.json なし / .gitignore 想定)"
  end
end

# =============================
# エラーログ出力（警告・成功いずれも追記）
# =============================
begin
  File.open("scripts/precommit_error.log", "a:utf-8") do |f|
    f.puts "=== #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ==="
    f.puts "[Branch]  #{`git rev-parse --abbrev-ref HEAD`.strip}"
    f.puts "[User]    #{`git config user.name`.strip} <#{`git config user.email`.strip}>"
    f.puts "[Files]   #{`git diff --cached --name-only`.strip.split("\n").join(', ')}"
    if warnings.empty?
      f.puts "✅ Passed with no issues"
    else
      warnings.each do |w|
        mark = (w.include?("エラー") || w.include?("中止")) ? "⛔" : "⚠️"
        f.puts "#{mark}  #{w}"
      end
      f.puts "⛔ 警告があるためコミットを中止します。"
    end
    f.puts "\n"
  end
rescue => e
  puts "⚠️ precommit_error.log への書き込みに失敗しました: #{e.message}"
end

# =============================
# 結果表示 & 終了コード
# =============================
puts "—— pre-commit report —————————————————————"
notes.each    { |m| puts "ℹ️  #{m}" }
warnings.each { |w| puts "⚠️  #{w}" }

if !warnings.empty?
  puts "⛔ 警告があるためコミットを中止します。"
  exit 1
end

after_changes = snapshot_changes
new_changes   = after_changes - BASELINE_CHANGES

if new_changes.empty?
  exit 0
end

# 生成物だけの新規差分か？
only_allowed_new = new_changes.all? { |p| allowed_generated_path?(p) }

if only_allowed_new
  if ENV["PRECOMMIT_AUTOSTAGE"] == "1"
    # 生成物を自動ステージ
    (new_changes.select { |p| allowed_generated_path?(p) }).each do |p|
      next unless File.exist?(p)
      system("git", "add", p)
    end
    # 再確認
    re_after      = snapshot_changes
    re_new        = re_after - BASELINE_CHANGES
    re_unexpected = re_new.reject { |p| allowed_generated_path?(p) }
    if re_unexpected.empty?
      puts "✅ 生成物をステージして通過（PRECOMMIT_AUTOSTAGE=1）"
      exit 0
    else
      puts "🛑 生成物以外の新規差分が残っています:"
      re_unexpected.each { |p| puts " - #{p}" }
      exit 1
    end
  else
    puts "🛑 フックが生成/更新したファイルがあります（生成物のみ）:"
    new_changes.each { |p| puts " - #{p}" }
    puts "内容を確認してから次のいずれかを実行してください："
    puts "  1) git add #{new_changes.join(' ')}"
    puts "     その後、再コミット。"
    puts "  2) 自動ステージで通す: PRECOMMIT_AUTOSTAGE=1 git commit ..."
    exit 1
  end
else
  # 生成物以外の新規差分が増えた → 止める
  unexpected = new_changes.reject { |p| allowed_generated_path?(p) }
  puts "🛑 フック実行中に生成物以外の新規差分が発生しました。確認してください："
  unexpected.each { |p| puts " - #{p}" }
  exit 1
end
