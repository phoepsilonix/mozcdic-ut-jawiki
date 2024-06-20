#! /usr/bin/env ruby
# coding: utf-8

# Author: UTUMI Hirosi (utuhiro78 at yahoo dot co dot jp)
# License: Apache License, Version 2.0

require 'bzip2/ffi'
require "cgi"
require 'nkf'
require 'open-uri'
require 'parallel'

# ==============================================================================
# Wikipediaの記事の例
# ==============================================================================

# Wikipediaの記事は「表記（読み）」を冒頭に書いているものが多い。
# これを使って表記と読みを取得する。

#       <text bytes="39506" xml:space="preserve">{{複数の問題
# | 出典の明記 = 2018年11月12日 (月) 08:46 (UTC)
# | 参照方法 = 2018年11月12日 (月) 08:46 (UTC)
# }}
# '''生物学'''（せいぶつがく、{{Lang-en-short|biology}}、

# ==============================================================================
# generate_jawiki_ut
# ==============================================================================

def generate_jawiki_ut

	# ==============================================================================
	# タイトルから表記を作る
	# ==============================================================================

	# タイトルを取得
	title = $article.split("</title>")[0]
	title = title.split("<title>")[1]

	# 記事を取得
	$article = $article.split(' xml:space="preserve">')[1]

	if $article == nil
		return
	end

	# タイトルの全角英数を半角に変換してUTF-8で出力
	# -m0 MIME の解読を一切しない
	# -Z1 全角空白を ASCII の空白に変換
	# -W 入力に UTF-8 を仮定する
	# -w UTF-8 を出力する(BOMなし)
	hyouki = NKF.nkf("-m0Z1 -W -w", title)

	# 表記を「 (」で切る
	# 田中瞳 (アナウンサー)
	hyouki = hyouki.split(' (')[0]

	# 表記が26文字以上の場合はスキップ。候補ウィンドウが大きくなりすぎる
	if hyouki[25] != nil ||
	# 内部用のページをスキップ
	hyouki.index("(曖昧さ回避)") != nil ||
	hyouki.index("Wikipedia:") != nil ||
	hyouki.index("ファイル:") != nil ||
	hyouki.index("Portal:") != nil ||
	hyouki.index("Help:") != nil ||
	hyouki.index("Template:") != nil ||
	hyouki.index("Category:") != nil ||
	hyouki.index("プロジェクト:") != nil ||
	# 表記にスペースがある場合はスキップ
	# 記事のスペースを削除してから「表記(読み」を検索するので、残してもマッチしない。
	hyouki.index(" ") != nil
		return
	end

	# 読みにならない文字「!?」などを削除したhyouki2を作る
	hyouki2 = hyouki.tr('\.\!\?\-\+\*\=\:\/・。×★☆', '')

	# hyouki2が1文字の場合はスキップ
	if hyouki2[1] == nil
		return
	end

	# hyouki2がひらがなとカタカナだけの場合は、読みをhyouki2から作る
	# さいたまスーパーアリーナ
	if hyouki2 == hyouki2.scan(/[ぁ-ゔァ-ヴー]/).join
		yomi = NKF.nkf("--hiragana -w -W", hyouki2)
		yomi = yomi.tr("ゐゑ", "いえ")

		s = [yomi, $id_mozc, $id_mozc, "8000", hyouki]

		# ファイルをロックして書き込む
		$dicfile.flock(File::LOCK_EX)
			$dicfile.puts s.join("	")
		$dicfile.flock(File::LOCK_UN)
		return
	end

	# ==============================================================================
	# 記事の量を減らす
	# ==============================================================================

	# テンプレート末尾と記事本文の間に改行を入れる
	lines = $article.gsub("}}'''", "}}\n'''")
	lines = lines.split("\n")

	s = []
	p = 0

	lines.length.times do |i|
		# テンプレートを削除
		# 収録語は「'''盛夏'''（せいか）」が最小なので、12文字以下の行はスキップ
		if lines[i][12] == nil ||
		lines[i][0] == "{" ||
		lines[i][0] == "}" ||
		lines[i][0] == "|" ||
		lines[i][0] == "*"
			next
		end

		s[p] = lines[i]
		p = p + 1

		# 記事を最大100行にする
		if p > 99
			break
		end
	end

	lines = s
	s = ""

	# ==============================================================================
	# 記事から読みを作る
	# ==============================================================================

	lines.length.times do |i|
		s = lines[i]

		# 全角英数を半角に変換してUTF-8で出力
		s = NKF.nkf("-m0Z1 -W -w", s)

		# HTML特殊文字を変換
		s = CGI.unescapeHTML(s)

		# 「{{」から「}}」までを削除
		# '''皆藤 愛子'''{{efn2|一部のプロフィールが「皆'''籐'''（たけかんむり）」となっているが、「皆'''藤'''（くさかんむり）」が正しい。}}（かいとう あいこ、[[1984年]][[1月25日]] - ）は、
		if s.index("{{") != nil
			s = s.gsub(/{{.*?}}/, "")
		end

		# 「<ref」から「</ref>」までを削除
		# '''井上 陽水'''（いのうえ ようすい<ref name="FMPJ">{{Cite web|和書|title=アーティスト・アーカイヴ 井上陽水 {{small|イノウエヨウスイ}}|url=https://www.kiokunokiroku.jp/artistarchives|work=記憶の記録 LIBRARY|publisher=[[日本音楽制作者連盟]]|accessdate=2023-06-21}}</ref>、[[1948年]]
		s = s.gsub(/<ref.*?<\/ref>/, "")

		# 「<ref name="example" />」を削除
		s = s.gsub(/<ref\ name.*?\/>/, "")

		# スペースと「'"「」『』」を削除
		# '''皆藤 愛子'''(かいとう あいこ、[[1984年]]
		s = s.tr(" '\"「」『』", "")

		# 「表記(読み」から読みを取得
		yomi = s.split(hyouki + "(")[1]

		if yomi == nil
			next
		end

		# 読みを「)」で切る
		# 結果が nil になって止まることがあるので、to_s で回避。
		yomi = yomi.split(")")[0].to_s

		# 読みを「[[」で切る
		# ないとうときひろ[[1963年]]
		yomi = yomi.split("[[")[0].to_s

		# 読みを「、」で切る
		# かいとうあいこ、[[1984年]]
		yomi = yomi.split("、")[0].to_s

		# 読みを「/」で切る
		# ひみこ/ひめこ
		yomi = yomi.split("/")[0].to_s

		# 読みが2文字以下の場合はスキップ
		if yomi[2] == nil
			next
		end

		# 読みが「ー」で始まる場合はスキップ
		if yomi[0] == "ー" ||
		# 読みが全てカタカナの場合はスキップ
		# ミュージシャン一覧(グループ)
		yomi == yomi.scan(/[ァ-ヴー]/).join
			next
		end

		# 読みのカタカナをひらがなに変換
		yomi = NKF.nkf("--hiragana -w -W", yomi)
		yomi = yomi.tr("ゐゑ", "いえ")

		# 読みがひらがな以外を含む場合はスキップ
		if yomi != yomi.scan(/[ぁ-ゔー]/).join
			next
		end

		s = [yomi, $id_mozc, $id_mozc, "8000", hyouki]

		# ファイルをロックして書き込む
		$dicfile.flock(File::LOCK_EX)
			$dicfile.puts s.join("	")
		$dicfile.flock(File::LOCK_UN)
		return
	end
end

# ==============================================================================
# main
# ==============================================================================

dicname = "mozcdic-ut-jawiki.txt"

# Mozc の一般名詞のID
url = "https://raw.githubusercontent.com/google/mozc/master/src/data/dictionary_oss/id.def"
$id_mozc = URI.open(url).read.split(" 名詞,一般,")[0]
$id_mozc = $id_mozc.split("\n")[-1]

`wget -N https://dumps.wikimedia.org/jawiki/latest/jawiki-latest-pages-articles-multistream.xml.bz2`

# Parallel のプロセス数を「物理コア数 - 1」にする
core_num = `grep cpu.cores /proc/cpuinfo`.chomp.split(": ")[-1].to_i - 1

$dicfile = File.new(dicname, "w")
jawiki_fragment = ""

reader = Bzip2::FFI::Reader.open('jawiki-latest-pages-articles-multistream.xml.bz2')

puts "Reading..."

while jawiki = reader.read(500000000)
	jawiki = jawiki.split("  </page>")
	jawiki[0] = jawiki_fragment + jawiki[0]

	# 記事の断片をキープ
	jawiki_fragment = jawiki[-1]

	# 記事の断片を削除
	jawiki = jawiki[0..-2]

	puts "Writing..."

	Parallel.map(jawiki, in_processes: core_num) do |s|
		$article = s
		generate_jawiki_ut
	end

	puts "Reading..."
end

reader.close

$dicfile.close

file = File.new(dicname, "r")
		lines = file.read.split("\n")
file.close

# 重複する行を削除
lines = lines.uniq.sort

file = File.new(dicname, "w")
		file.puts lines
file.close
