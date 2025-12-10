#!/bin/bash
set -euo pipefail

# Unified entrypoint for Git Image Preprocessor
# Uses ImageMagick `convert` for all conversions and optimizations, applies -strip when requested,
# unified convert flow: uses ImageMagick `convert`, applies -strip, resizes if needed, re-encodes
# with specified quality, compares sizes, replaces only if smaller.

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

echo "Git Image Preprocessor (unified convert) starting"
echo "QUALITY=$QUALITY"
echo "MAX_WIDTH=$MAX_WIDTH"
echo "MAX_HEIGHT=$MAX_HEIGHT"
if [ -n "$CONVERT_TO" ]; then
	echo "CONVERT_TO=$CONVERT_TO"
fi
echo "REMOVE_EXIF=$REMOVE_EXIF"
echo "MAX_SIZE_KB=$MAX_SIZE_KB"

if ! command -v convert >/dev/null 2>&1; then
	echo "ImageMagick 'convert' is required. Please install imagemagick with HEIC/AVIF support." >&2
	exit 1
fi

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

get_file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# Build strip arg for ImageMagick convert (applies to all conversions/optimizations)
if [ "$REMOVE_EXIF" = "true" ]; then
	STRIP_ARG=(-strip)
else
	STRIP_ARG=()
fi

build_resize_args() {
	# build_resize_args <src>
	# Determine which dimension exceeds its MAX proportionally more and build sequential
	# resize args to preserve aspect ratio. The first resize will target the dimension with
	# the larger relative overflow, followed by the other if needed.
	local src="$1"
	local resize_args=()
	# if neither max is set, no resize
	if [[ "$MAX_WIDTH" == "0" && "$MAX_HEIGHT" == "0" ]]; then
		echo ""
		return 0
	fi
	# require identify
	if ! command -v identify >/dev/null 2>&1; then
		# fallback: same as previous simple resize args
		if [[ "$MAX_WIDTH" != "0" ]]; then
			resize_args+=(-resize "${MAX_WIDTH}x>")
		fi
		if [[ "$MAX_HEIGHT" != "0" ]]; then
			resize_args+=(-resize "x${MAX_HEIGHT}>")
		fi
		echo "${resize_args[@]}"
		return 0
	fi
	# get dimensions
	local dims
	dims=$(identify -format "%w %h" "$src" 2>/dev/null || echo "0 0")
	local iw ih
	read -r iw ih <<<"$dims"
	if [[ "$iw" -le 0 || "$ih" -le 0 ]]; then
		echo ""
		return 0
	fi

	# compute overflow ratios (only if max set)
	local wr hr
	wr=0
	hr=0
	if [[ "$MAX_WIDTH" != "0" ]]; then
		wr=$(awk "BEGIN {printf \"%.6f\", $iw/$MAX_WIDTH}")
	fi
	if [[ "$MAX_HEIGHT" != "0" ]]; then
		hr=$(awk "BEGIN {printf \"%.6f\", $ih/$MAX_HEIGHT}")
	fi

	# if neither exceeds, nothing to do
	local wex=0 hex=0
	if (($(awk "BEGIN{print ($wr>1)}"))); then wex=1; fi
	if (($(awk "BEGIN{print ($hr>1)}"))); then hex=1; fi
	if [[ $wex -eq 0 && $hex -eq 0 ]]; then
		echo ""
		return 0
	fi

	# Decide which dimension to do first (larger overflow gets first resize)
	if [[ $wex -eq 1 && $hex -eq 1 ]]; then
		# both exceed; pick whichever ratio is bigger
		if (($(awk "BEGIN{print ($wr >= $hr)}"))); then
			# width first
			resize_args+=(-resize "${MAX_WIDTH}x>")
			# compute new height after width resize and decide if height resize needed
			local new_h
			new_h=$(awk "BEGIN {printf \"%.0f\", $ih * ($MAX_WIDTH / $iw)}")
			if (($(awk "BEGIN{print ($new_h > $MAX_HEIGHT)}"))); then
				resize_args+=(-resize "x${MAX_HEIGHT}>")
			fi
		else
			# height first
			resize_args+=(-resize "x${MAX_HEIGHT}>")
			# compute new width after height resize and decide if width resize needed
			local new_w
			new_w=$(awk "BEGIN {printf \"%.0f\", $iw * ($MAX_HEIGHT / $ih)}")
			if (($(awk "BEGIN{print ($new_w > $MAX_WIDTH)}"))); then
				resize_args+=(-resize "${MAX_WIDTH}x>")
			fi
		fi
	elif [[ $wex -eq 1 ]]; then
		resize_args+=(-resize "${MAX_WIDTH}x>")
	elif [[ $hex -eq 1 ]]; then
		resize_args+=(-resize "x${MAX_HEIGHT}>")
	fi
	echo "${resize_args[@]}"
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

	case "$ext" in
	jpg | jpeg | webp)
		# Binary search on quality to produce best quality <= target
		local low=5
		local high=$((orig_quality - 1))
		if [ $high -lt $low ]; then high=$low; fi
		local candidate="" candidate_size=0
		local iter=0
		while [ $low -le $high ] && [ $iter -lt 12 ]; do
			iter=$((iter + 1))
			local mid=$(((low + high) / 2))
			local tmp_try="${tmp_current%.*}.q${mid}.tmp"
			# Re-encode from original with quality mid
			local cmd=(convert "$src")
			cmd+=("${STRIP_ARG[@]}")
			if [ -n "$rargs" ]; then
				# shellcheck disable=SC2206
				cmd+=($rargs)
			fi
			cmd+=(-quality "$mid" "$tmp_try")
			"${cmd[@]}" >/dev/null 2>&1 || {
				rm -f "$tmp_try" 2>/dev/null || true
				high=$((mid - 1))
				continue
			}
			local s_try
			s_try=$(get_file_size "$tmp_try")
			if [ $s_try -le $target_bytes ]; then
				candidate="$tmp_try"
				candidate_size=$s_try
				# try higher quality to get closer to target
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
			else
				# candidate too small (<95%); try slight increase
				local q=$((low - 1))
				while [ $q -le $orig_quality ] && [ $q -ge 5 ]; do
					local tmp_try2="${tmp_current%.*}.q${q}.tmp"
					local cmd=(convert "$src")
					cmd+=("${STRIP_ARG[@]}")
					if [ -n "$rargs" ]; then
						# shellcheck disable=SC2206
						cmd+=($rargs)
					fi
					cmd+=(-quality "$q" "$tmp_try2")
					"${cmd[@]}" >/dev/null 2>&1 || {
						rm -f "$tmp_try2" 2>/dev/null || true
						q=$((q + 1))
						continue
					}
					local s2
					s2=$(get_file_size "$tmp_try2")
					if [ $s2 -le $target_bytes ] && [ $s2 -ge $min_allowed ]; then
						FINAL_TMP="$tmp_try2"
						return 0
					fi
					rm -f "$tmp_try2" 2>/dev/null || true
					q=$((q + 1))
				done
				FINAL_TMP="$candidate"
				return 0
			fi
		fi
		return 1
		;;
	png)
		# Try pngquant - starting at higher quality and decreasing
		local base_tmp="${tmp_current%.*}.png.tmp"
		local cmd=(convert "$src")
		cmd+=("${STRIP_ARG[@]}")
		if [ -n "$rargs" ]; then
			# shellcheck disable=SC2206
			cmd+=($rargs)
		fi
		cmd+=("$base_tmp")
		"${cmd[@]}" >/dev/null 2>&1 || return 1
		local qlist=(90 85 80 75 70 65 60 55 50 45 40)
		for q in "${qlist[@]}"; do
			local minq=$((q - 10))
			if [ $minq -lt 10 ]; then minq=10; fi
			local tmp_try="${base_tmp%.tmp}.pq${q}.png"
			pngquant --quality="$minq-$q" --output "$tmp_try" --force "$base_tmp" >/dev/null 2>&1 || {
				rm -f "$tmp_try" 2>/dev/null || true
				continue
			}
			local s_try
			s_try=$(get_file_size "$tmp_try")
			if [ $s_try -le $target_bytes ]; then
				FINAL_TMP="$tmp_try"
				rm -f "$base_tmp" 2>/dev/null || true
				return 0
			fi
			rm -f "$tmp_try" 2>/dev/null || true
		done
		rm -f "$base_tmp" 2>/dev/null || true
		return 1
		;;
	*)
		return 1
		;;
	esac
}

convert_image() {
	# Usage: convert_image <src> <target_ext>
	local src="$1"
	local tgt="$2"
	local dst="${src%.*}.${tgt}"
	local tmp="${dst}.tmp"
	echo "Converting: $src -> $dst"

	# Build convert command
	local cmd=(convert "$src")
	# Apply -strip first (if requested) to ensure we drop metadata before conversion
	cmd+=("${STRIP_ARG[@]}")

	# Resize if requested
	local rargs
	rargs=$(build_resize_args "$src")
	if [ -n "$rargs" ]; then
		# shellcheck disable=SC2206
		cmd+=($rargs)
	fi

	# Configure quality/encoding
	case "$tgt" in
	webp)
		cmd+=(-quality "$QUALITY" "$tmp")
		;;
	png)
		# For PNG, convert can output directly; not adding quality but use optimization later
		cmd+=("$tmp")
		;;
	jpg | jpeg)
		cmd+=(-quality "$QUALITY" "$tmp")
		;;
	*)
		cmd+=("$tmp")
		;;
	esac

	# Execute convert
	"${cmd[@]}" >/dev/null 2>&1 || return 1

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
	convert_image "$f" "$target_ext"
	local status=$?
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
				ensure_max_size "$f" "$tmp_out" "$target_ext" "$target_bytes" "$QUALITY"
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

echo "Scanning patterns: $FILE_PATTERNS"
for pattern in $FILE_PATTERNS; do while IFS= read -r -d '' f; do
	[ -f "$f" ] || continue
	process_file "$f"
done < <(find . -type f -iname "$pattern" -print0); done

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
