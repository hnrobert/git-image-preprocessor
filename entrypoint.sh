#!/bin/bash
set -euo pipefail

# Unified entrypoint for Git Image Preprocessor
# Uses ImageMagick `convert` for all conversions and optimizations, applies -strip when requested,
# unified convert flow: uses ImageMagick `convert`, applies -strip, and avoids ffmpeg/cwebp fallbacks.

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

echo "Git Image Preprocessor (unified convert) starting"
echo "Q:$QUALITY MAX:${MAX_WIDTH}x${MAX_HEIGHT} CONVERT_TO:'$CONVERT_TO'"

echo "QUALITY=$QUALITY"
echo "MAX_WIDTH=$MAX_WIDTH"
echo "MAX_HEIGHT=$MAX_HEIGHT"
if [ -n "$CONVERT_TO" ]; then
	echo "CONVERT_TO=$CONVERT_TO"
fi
echo "REMOVE_EXIF=$REMOVE_EXIF"

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
	local resize_args=()
	if [[ "$MAX_WIDTH" != "0" || "$MAX_HEIGHT" != "0" ]]; then
		if [[ "$MAX_WIDTH" != "0" && "$MAX_HEIGHT" != "0" ]]; then
			resize_args+=(-resize "${MAX_WIDTH}x${MAX_HEIGHT}>")
		elif [[ "$MAX_WIDTH" != "0" ]]; then
			resize_args+=(-resize "${MAX_WIDTH}x>")
		else
			resize_args+=(-resize "x${MAX_HEIGHT}>")
		fi
	fi
	echo "${resize_args[@]}"
}

convert_image() {
	# Usage: convert_image <src> <target_ext>
	local src="$1" tgt="$2" dst="${src%.*}.${tgt}" tmp="${dst}.tmp"
	echo "Converting: $src -> $dst"

	# Build convert command
	local cmd=(convert "$src")
	# Apply -strip first (if requested) to ensure we drop metadata before conversion
	cmd+=("${STRIP_ARG[@]}")

	# Resize if requested
	local rargs
	rargs=$(build_resize_args)
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

	# Move the file into place, remove original
	mv "$tmp" "$dst"
	rm -f "$src" || true
	CHANGED_FILES+=("$dst")
	echo "  ✅ Converted saved $((s - d)) bytes"
	return 0
}

process_file() {
	local f="$1" ext="${f##*.}"
	ext=${ext,,}
	local target_ext="$ext"

	# Determine if we should convert to a different extension
	if [ -n "$CONVERT_TO" ] && [[ "$ext" =~ ^(gif|bmp|tiff|tif|heic|heif|avif)$ ]]; then
		target_ext="$CONVERT_TO"
	fi

	# Re-encode using convert even when target is same type to apply quality/strip/resize
	local orig_size=$(get_file_size "$f")
	convert_image "$f" "$target_ext"
	local status=$?
	if [ $status -eq 0 ]; then
		local new_file="${f%.*}.${target_ext}"
		local new_size=$(get_file_size "$new_file")
		if [ $new_size -lt $orig_size ]; then
			echo "  ✅ Processed $f -> $new_file; saved $((orig_size - new_size)) bytes"
			OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
			TOTAL_SAVED=$((TOTAL_SAVED + orig_size - new_size))
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
