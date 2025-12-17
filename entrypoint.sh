#!/bin/bash
set -euo pipefail

# Unified entrypoint for Git Image Preprocessor
# Uses ffmpeg for all conversions and optimizations, removes metadata when requested,
# resizes if needed, re-encodes with specified quality, compares sizes, replaces only if smaller.

QUALITY=${1:-85}
MAX_WIDTH=${2:-0}
MAX_HEIGHT=${3:-0}
GIT_USER_NAME=${4:-github-actions[bot]}
GIT_USER_EMAIL=${5:-github-actions[bot]@users.noreply.github.com}
COMMIT_MESSAGE=${6:-"🖼️ Optimize images"}
FILE_PATTERNS=${7:-"*.jpg *.jpeg *.png *.webp *.heic *.heif *.avif *.tiff *.bmp *.gif"}
SKIP_CI=${8:-false}
REMOVE_EXIF=${9:-true}
CONVERT_TO=${10:-""}
MAX_SIZE_KB=${11:-0}
SCAN_WHOLE_REPO=${12:-false}

echo "Git Image Preprocessor starting"
echo "QUALITY=$QUALITY"
echo "MAX_WIDTH=$MAX_WIDTH"
echo "MAX_HEIGHT=$MAX_HEIGHT"
if [ -n "$CONVERT_TO" ]; then
	echo "CONVERT_TO=$CONVERT_TO"
fi
echo "REMOVE_EXIF=$REMOVE_EXIF"
echo "MAX_SIZE_KB=$MAX_SIZE_KB"
echo "SCAN_WHOLE_REPO=$SCAN_WHOLE_REPO"

if ! command -v ffmpeg >/dev/null 2>&1; then
	echo "ffmpeg is required. Please install ffmpeg." >&2
	exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
	echo "ffprobe is required. Please install ffmpeg." >&2
	exit 1
fi

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

get_file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# Build metadata removal flag for ffmpeg
if [ "$REMOVE_EXIF" = "true" ]; then
	METADATA_ARGS=(-map_metadata -1)
else
	METADATA_ARGS=()
fi

build_resize_args() {
	# build_resize_args <src>
	# Returns ffmpeg scale filter string if resize needed, empty otherwise
	local src="$1"
	# if neither max is set, no resize
	if [[ "$MAX_WIDTH" == "0" && "$MAX_HEIGHT" == "0" ]]; then
		echo ""
		return 0
	fi
	# get dimensions using ffprobe
	local iw ih
	iw=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$src" 2>/dev/null || echo 0)
	ih=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$src" 2>/dev/null || echo 0)
	if [[ "$iw" -le 0 || "$ih" -le 0 ]]; then
		echo ""
		return 0
	fi

	# Build scale filter: scale='min(MAX_WIDTH,iw):min(MAX_HEIGHT,ih):force_original_aspect_ratio=decrease'
	local scale_filter=""
	if [[ "$MAX_WIDTH" != "0" && "$MAX_HEIGHT" != "0" ]]; then
		scale_filter="scale='min($MAX_WIDTH,iw)':'min($MAX_HEIGHT,ih)':force_original_aspect_ratio=decrease"
	elif [[ "$MAX_WIDTH" != "0" ]]; then
		scale_filter="scale='min($MAX_WIDTH,iw)':-1"
	elif [[ "$MAX_HEIGHT" != "0" ]]; then
		scale_filter="scale=-1:'min($MAX_HEIGHT,ih)'"
	fi
	echo "$scale_filter"
}

ensure_max_size() {
	# ensure_max_size <orig_src> <tmp_current> <ext> <target_bytes> <orig_quality>
	local src="$1"
	local tmp_current="$2"
	local ext="$3"
	local target_bytes="$4"
	local orig_quality="$5"
	FINAL_TMP=""
	[ -f "$tmp_current" ] || return 1
	local cur_size
	cur_size=$(get_file_size "$tmp_current")
	if [ $cur_size -le $target_bytes ]; then
		FINAL_TMP="$tmp_current"
		return 0
	fi
	# Prepare resize args from original image
	local rargs
	rargs=$(build_resize_args "$src")

	# Binary search on quality for all formats using ffmpeg
	local low=5
	local high=$((orig_quality - 1))
	if [ $high -lt $low ]; then high=$low; fi
	local candidate="" candidate_size=0
	local iter=0
	while [ $low -le $high ] && [ $iter -lt 12 ]; do
		iter=$((iter + 1))
		local mid=$(((low + high) / 2))
		local tmp_try="${tmp_current%.*}.q${mid}.tmp"
		# Re-encode from original with quality mid using ffmpeg
		local ff_cmd=(ffmpeg -y -i "$src")
		ff_cmd+=("${METADATA_ARGS[@]}")
		if [ -n "$rargs" ]; then
			ff_cmd+=(-vf "$rargs")
		fi
		# Set quality based on format
		case "$ext" in
		jpg | jpeg)
			ff_cmd+=(-q:v "$mid")
			;;
		webp)
			ff_cmd+=(-q:v "$mid")
			;;
		png)
			ff_cmd+=(-compression_level 9)
			;;
		esac
		ff_cmd+=("$tmp_try")
		"${ff_cmd[@]}" >/dev/null 2>&1 || {
			rm -f "$tmp_try" 2>/dev/null || true
			high=$((mid - 1))
			continue
		}
		local s_try
		s_try=$(get_file_size "$tmp_try")
		if [ $s_try -le $target_bytes ]; then
			candidate="$tmp_try"
			candidate_size=$s_try
			low=$((mid + 1))
		else
			rm -f "$tmp_try" 2>/dev/null || true
			high=$((mid - 1))
		fi
	done
	if [ -n "$candidate" ]; then
		local min_allowed=$(awk "BEGIN {printf \"%d\", $target_bytes * 0.95}")
		if [ $candidate_size -ge $min_allowed ]; then
			FINAL_TMP="$candidate"
			return 0
		fi
	fi
	return 1
}

convert_image() {
	# Usage: convert_image <src> <target_ext>
	local src="$1"
	local tgt="$2"
	local dst="${src%.*}.${tgt}"
	local tmp="${dst}.tmp"
	echo "Converting: $src -> $dst"

	# Build ffmpeg command
	local cmd=(ffmpeg -y -i "$src")
	# Apply metadata removal if requested
	cmd+=("${METADATA_ARGS[@]}")

	# Resize if requested
	local scale_filter
	scale_filter=$(build_resize_args "$src")
	if [ -n "$scale_filter" ]; then
		cmd+=(-vf "$scale_filter")
	fi

	# Configure quality/encoding based on target format
	case "$tgt" in
	webp)
		cmd+=(-q:v "$QUALITY")
		;;
	png)
		cmd+=(-compression_level 9)
		;;
	jpg | jpeg)
		cmd+=(-q:v "$QUALITY")
		;;
	esac
	cmd+=("$tmp")

	# Execute ffmpeg and capture stderr for debugging when it fails
	local log_file="${tmp}.log"
	if ! "${cmd[@]}" >/dev/null 2>"$log_file"; then
		echo "  ⚠️ ffmpeg failed for $src -> $dst; output: $(sed -n '1,120p' "$log_file" 2>/dev/null || true)" >&2
		rm -f "$log_file" 2>/dev/null || true
		return 1
	fi
	rm -f "$log_file" 2>/dev/null || true

	# Validate and compare sizes
	[ -f "$tmp" ] || return 1
	local s d
	s=$(get_file_size "$src")
	d=$(get_file_size "$tmp")
	if [ $d -ge $s ]; then
		rm -f "$tmp"
		# Return 2 means produced file is not smaller
		return 2
	fi

	# Keep tmp in place for potential post-processing (size constraint), do not remove original yet
	LAST_TMP="$tmp"
	LAST_DST="$dst"
	echo "  ✅ Converted (tmp saved) saved $((s - d)) bytes"
	return 0
}

process_file() {
	local f="$1" ext="${f##*.}"
	ext=${ext,,}
	local target_ext="$ext"

	# Normalize extension aliases for comparison (jpeg->jpg, tif->tiff)
	local norm_ext="$ext"
	if [ "$norm_ext" = "jpeg" ]; then
		norm_ext="jpg"
	elif [ "$norm_ext" = "tif" ]; then
		norm_ext="tiff"
	fi

	# Determine if we should convert to a different extension
	# If convert-to is set and the image is not already the target format, convert.
	if [ -n "$CONVERT_TO" ]; then
		local norm_target
		norm_target="${CONVERT_TO,,}"
		if [ "$norm_target" = "jpeg" ]; then norm_target="jpg"; fi
		if [ "$norm_ext" != "$norm_target" ]; then
			target_ext="$CONVERT_TO"
		fi
	fi

	# Re-encode using convert even when target is same type to apply quality/strip/resize
	local orig_size=$(get_file_size "$f")
	# Call convert_image but avoid set -e causing an exit. Capture status explicitly.
	set +e
	convert_image "$f" "$target_ext"
	local status=$?
	set -e
	if [ $status -eq 0 ]; then
		# The converted temporary file path is available in $LAST_TMP
		local tmp_out="$LAST_TMP"
		local new_file="${f%.*}.${target_ext}"
		local new_size=$(get_file_size "$tmp_out")
		# If max-size-kb specified, enforce size target by re-encoding from original image
		if [[ "$MAX_SIZE_KB" != "0" && "$MAX_SIZE_KB" != "" ]]; then
			# compute byte target
			local target_bytes=$((MAX_SIZE_KB * 1024))
			if [ $new_size -gt $target_bytes ]; then
				# try to reduce using ensure_max_size, which creates a new final file at tmp_final
				# Attempt to ensure max size but do not exit the entire script on failure
				set +e
				ensure_max_size "$f" "$tmp_out" "$target_ext" "$target_bytes" "$QUALITY"
				local em_status=$?
				set -e
				# ensure_max_size sets FINAL_TMP on success
				if [ -n "${FINAL_TMP:-}" ] && [ -f "$FINAL_TMP" ]; then
					tmp_out="$FINAL_TMP"
					new_size=$(get_file_size "$tmp_out")
				fi
			fi
		fi
		if [ $new_size -lt $orig_size ]; then
			# Move final tmp_out to final destination
			mv "$tmp_out" "$new_file"
			# remove initial LAST_TMP if it's different and exists
			if [ -n "${LAST_TMP:-}" ] && [ "$LAST_TMP" != "$tmp_out" ]; then
				rm -f "$LAST_TMP" || true
			fi
			# If new_file differs from the original file path, remove the original
			if [ "$new_file" != "$f" ]; then
				rm -f "$f" || true
			fi
			CHANGED_FILES+=("$new_file")
			echo "  ✅ Processed $f -> $new_file; saved $((orig_size - new_size)) bytes"
			OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
			TOTAL_SAVED=$((TOTAL_SAVED + orig_size - new_size))
			# clear FINAL_TMP and LAST_TMP
			FINAL_TMP=""
			LAST_TMP=""
		else
			# no improvement - remove tmp files and skip replacement
			rm -f "$tmp_out" || true
		fi
		return 0
	elif [ $status -eq 2 ]; then
		echo "  ⚠️ Converted $f produced larger file; skipped replacement"
		return 2
	else
		echo "  ⚠️ Conversion failed for $f"
		return 1
	fi
}

CHANGED_FILES=()
OPTIMIZED_COUNT=0
TOTAL_SAVED=0

FINAL_TMP=""
LAST_TMP=""

cleanup_tmp() {
	[ -n "${LAST_TMP:-}" ] && rm -f "$LAST_TMP" 2>/dev/null || true
	[ -n "${FINAL_TMP:-}" ] && rm -f "$FINAL_TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT

get_changed_files() {
	# Get list of changed files in PR (works for both push and pull_request events)
	local changed_files=()
	if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
		# For PR: compare against base branch name in GITHUB_BASE_REF
		local base_branch="${GITHUB_BASE_REF:-}"
		if [ -n "$base_branch" ]; then
			# Try to fetch the base branch; ignore failures
			git fetch origin "$base_branch" --depth=1 2>/dev/null || git fetch origin "$base_branch":"$base_branch" --depth=1 2>/dev/null || true

			# Prefer diff against origin/base_branch...HEAD
			local diff_out
			if git rev-parse --verify "origin/$base_branch" >/dev/null 2>&1; then
				diff_out=$(git diff --name-only "origin/$base_branch"...HEAD 2>/dev/null || true)
				if [ -z "$diff_out" ]; then
					diff_out=$(git diff --name-only "origin/$base_branch"..."${GITHUB_SHA:-HEAD}" 2>/dev/null || true)
				fi
			else
				# origin/base not available; try a safe HEAD~1 diff if parent exists
				if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
					diff_out=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
				else
					diff_out=$(git show --name-only --pretty=format: "${GITHUB_SHA:-HEAD}" 2>/dev/null || true)
				fi
			fi

			# Collect existing files only
			if [ -n "$diff_out" ]; then
				while IFS= read -r file; do
					[ -n "$file" ] && [ -f "$file" ] && changed_files+=("$file")
				done < <(printf '%s\n' "$diff_out")
			fi
		fi
	else
		# For push: get files changed in the last commit, but only if parent exists
		if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
			local diff_out
			diff_out=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
			if [ -n "$diff_out" ]; then
				while IFS= read -r file; do
					[ -n "$file" ] && [ -f "$file" ] && changed_files+=("$file")
				done < <(printf '%s\n' "$diff_out")
			fi
		else
			# No parent commit; fall back to listing files in current tree
			while IFS= read -r file; do
				[ -n "$file" ] && [ -f "$file" ] && changed_files+=("$file")
			done < <(git ls-tree -r --name-only HEAD 2>/dev/null || true)
		fi
	fi
	printf '%s\0' "${changed_files[@]}"
}

write_summary() {
	# write summary lines to GITHUB_STEP_SUMMARY if available
	local title="$1"
	shift
	local arr=("$@")
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## $title"
			for item in "${arr[@]}"; do
				echo "- $item"
			done
			echo
		} >>"$GITHUB_STEP_SUMMARY"
	fi
}

echo "Scanning patterns: $FILE_PATTERNS"

if [ "$SCAN_WHOLE_REPO" = "false" ]; then
	echo "Scanning only changed files in PR/commit"
	# Get changed files and filter by patterns
	declare -a all_changed_files
	mapfile -d $'\0' -t all_changed_files < <(get_changed_files)

	if [ ${#all_changed_files[@]} -eq 0 ]; then
		echo "  ⚠️ No changed files detected in PR/commit"
	else
		echo "Changed files in PR/commit (${#all_changed_files[@]}):"
		for cf in "${all_changed_files[@]}"; do
			echo "  - $cf"
		done
		write_summary "Image Preprocessor - PR changed files" "${all_changed_files[@]}"
	fi

	declare -A processed_files
	declare -a files_to_process
	for changed_file in "${all_changed_files[@]}"; do
		[ -f "$changed_file" ] || continue
		# case-insensitive match: compare lowercased values
		lname=$(printf '%s' "$changed_file" | tr '[:upper:]' '[:lower:]')
		for pattern in $FILE_PATTERNS; do
			lpattern=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
			if [[ "$lname" == $lpattern ]] || [[ "$(basename "$lname")" == $lpattern ]]; then
				if [ -z "${processed_files[$changed_file]:-}" ]; then
					processed_files[$changed_file]=1
					files_to_process+=("$changed_file")
				fi
				break
			fi
		done
	done

	if [ ${#files_to_process[@]} -eq 0 ]; then
		echo "No files matching patterns were found in the changed files."
	else
		echo "Files matching configured patterns (${#files_to_process[@]}):"
		for f in "${files_to_process[@]}"; do
			echo "  - $f"
		done
		write_summary "Image Preprocessor - Files to process" "${files_to_process[@]}"
	fi

	# Process matching files
	for f in "${files_to_process[@]}"; do
		set +e
		process_file "$f"
		pf_status=$?
		set -e
		if [ $pf_status -ne 0 ]; then
			echo "  ⚠️ Processing returned non-zero status $pf_status for file $f" >&2
		fi
	done
else
	echo "Scanning entire repository"
	declare -a files_to_process
	for pattern in $FILE_PATTERNS; do
		while IFS= read -r -d '' f; do
			[ -f "$f" ] || continue
			files_to_process+=("$f")
		done < <(find . -type f -iname "$pattern" -print0)
	done

	if [ ${#files_to_process[@]} -eq 0 ]; then
		echo "No files matching configured patterns were found in the repository."
	else
		echo "Files matching configured patterns (${#files_to_process[@]}):"
		for f in "${files_to_process[@]}"; do
			echo "  - $f"
		done
		write_summary "Image Preprocessor - Files to process" "${files_to_process[@]}"
	fi

	# Process matching files
	for f in "${files_to_process[@]}"; do
		set +e
		process_file "$f"
		pf_status=$?
		set -e
		if [ $pf_status -ne 0 ]; then
			echo "  ⚠️ Processing returned non-zero status $pf_status for file $f" >&2
		fi
	done
fi

echo "Done. Optimized: $OPTIMIZED_COUNT files, saved $TOTAL_SAVED bytes"
echo "optimized-count=$OPTIMIZED_COUNT" >>$GITHUB_OUTPUT
echo "total-saved=$TOTAL_SAVED" >>$GITHUB_OUTPUT
echo "files-changed=${CHANGED_FILES[*]}" >>$GITHUB_OUTPUT

if [ $OPTIMIZED_COUNT -gt 0 ]; then
	echo "Committing changes..."
	for f in "${CHANGED_FILES[@]}"; do git add "$f"; done
	[ "$SKIP_CI" = "true" ] && COMMIT_MESSAGE="$COMMIT_MESSAGE [skip ci]"
	git commit -m "$COMMIT_MESSAGE" || true
fi

echo "Finished"
