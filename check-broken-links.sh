#!/bin/bash
# check for arguments
if [[ $# -eq 0 ]]; then
	echo 'No URL supplied'
	exit 1
fi

user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'

# check links with muffet (brew install muffet): on all pages of the site, or with --one-page-only on the given page,
# and print one "error<TAB>page<TAB>link" line per failed link
#   --buffer-size: some sites (e.g. GitHub) send response headers larger than the 4 KB default
#   --max-connections*, --timeout: with muffet's default of 512 parallel connections many requests time out
#   User-Agent: Wikipedia, LinkedIn and others block non-browser clients
#   --exclude: links that only work on a developer's machine (localhost, *.local),
#     and Cloudflare email protection links, which return 404 until JavaScript rewrites them in the browser
#   --ignore-fragments: check only that the linked page exists, not the #anchor on it
check_links() {
	local muffet_output
	muffet_output=$(muffet \
		--buffer-size 65536 \
		--max-connections 8 \
		--max-connections-per-host 4 \
		--timeout 20 \
		--header "User-Agent: $user_agent" \
		--exclude '^https?://(localhost|127\.0\.0\.1|[^/]+\.local)([:/]|$)' \
		--exclude '/cdn-cgi/l/email-protection' \
		--ignore-fragments \
		"$@")
	# muffet failed without listing any page, i.e. it could not fetch the start URL (it printed why)
	if [[ $? -ne 0 && -z $muffet_output ]]; then
		return 1
	fi
	echo "$muffet_output" | awk -F'\t' '/^[^\t]/ { page = $0 } /^\t/ { print $2 "\t" page "\t" $3 }'
}

failed_links=$(check_links "$1") || exit 1

# keep 404s; other HTTP errors are mostly bot protection or rate limits, not broken links
broken_links=$(echo "$failed_links" | awk -F'\t' '$1 == "404"')

# muffet does not retry timeouts (its --max-retries misses fasthttp's timeout error), so check the links that got
# no HTTP response once more with curl, one at a time, and list the ones that still fail instead of dropping them
site=$(echo "$1" | awk -F/ '{ print $1 "//" $3 "/" }')
while IFS=$'\t' read -r _ page link; do
	# links are sorted, so a link on several pages is checked only once
	if [[ $link != "$last_link" ]]; then
		last_link=$link
		result=$(curl --silent --output /dev/null --location --max-time 60 --range 0-0 --user-agent "$user_agent" \
			--write-out '%{http_code}\t%{exitcode}\t%{content_type}' "$link")
		IFS=$'\t' read -r status exit_code content_type <<< "$result"
		# a page of the site that muffet could not load: its links were never checked, check them now
		if [[ $status == 2* && $content_type == text/html* && $link == "$site"* ]]; then
			broken_links+=$'\n'$(check_links --one-page-only "$link" | awk -F'\t' '$1 == "404"')
		fi
	fi
	case $status in
		404) broken_links+=$'\n'"404"$'\t'"$page"$'\t'"$link" ;;
		000)
			case $exit_code in
				28) error='timeout' ;;
				3) error='invalid URL' ;;
				6) error='unknown host' ;;
				*) error="curl error $exit_code" ;;
			esac
			broken_links+=$'\n'"$error"$'\t'"$page"$'\t'"$link" ;;
	esac
done < <(echo "$failed_links" | awk -F'\t' '$1 !~ /^[0-9]+$/' | sort -t $'\t' -k 3)

# print the broken links as markdown tables, one for pages and one for images and other media (by the link's file
# extension), sorted by error and page ("|" in URLs is escaped so it doesn't split cells)
broken_links=$(echo "$broken_links" | awk NF | sort)
if [[ -n $broken_links ]]; then
	echo "$broken_links" | awk -F'\t' '
		function table(title, rows) {
			if (rows == "") return
			if (printed++) print ""
			print "## " title
			print ""
			print "| Error code | Page URL | Link URL |"
			print "| --- | --- | --- |"
			printf "%s", rows
		}
		{
			# file extension of the last path segment, ignoring query, fragment and trailing slashes
			name = $3; sub(/[?#].*/, "", name); sub(/\/+$/, "", name); sub(/.*\//, "", name)
			extension = tolower(name); if (!sub(/.*\./, "", extension)) extension = ""
			gsub(/\|/, "\\|")
			row = "| " $1 " | " $2 " | " $3 " |\n"
			# images, video, audio, downloads, and the stylesheets, scripts and fonts pages load
			if (extension ~ /^(avif|bmp|gif|ico|jpe?g|png|svg|tiff?|webp|m4v|mov|mp4|ogv|webm|m4a|mp3|ogg|wav|pdf|zip|css|js|woff2?|ttf|otf|eot)$/) media = media row
			else pages = pages row
		}
		END { table("Pages", pages); table("Images and other media", media) }
	'
	exit 1
fi

# otherwise, exit silently with success
exit 0
