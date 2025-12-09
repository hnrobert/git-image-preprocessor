#!/bin/bash
set -e

# Get input parameters
QUALITY=$1
PNG_QUALITY=$2
WEBP_QUALITY=$3
MAX_WIDTH=$4
MAX_HEIGHT=$5
CONVERT_TO_WEBP=$6
GIT_USER_NAME=$7
GIT_USER_EMAIL=$8
COMMIT_MESSAGE=$9
FILE_PATTERNS=${10}
SKIP_CI=${11}
REMOVE_EXIF=${12}

echo "🖼️ Git Image Preprocessor Action"
echo "=========================="
echo "Quality: $QUALITY"
echo "PNG Quality: $PNG_QUALITY"
echo "WebP Quality: $WEBP_QUALITY"
echo "Max Width: $MAX_WIDTH"
echo "Max Height: $MAX_HEIGHT"
echo "Convert to WebP: $CONVERT_TO_WEBP"
echo "Remove EXIF: $REMOVE_EXIF"
echo "File Patterns: $FILE_PATTERNS"
echo ""

# Initialize counters
OPTIMIZED_COUNT=0
TOTAL_SAVED=0
CHANGED_FILES=()

# Configure git
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# Function to get file size
get_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# Function to optimize JPEG
optimize_jpeg() {
    local file=$1
    local temp_file="${file}.tmp"
    
    echo "Optimizing JPEG: $file"
    
    local original_size=$(get_file_size "$file")
    
    # Build ImageMagick command
    local cmd="convert \"$file\""
    
    # Remove EXIF data if enabled
    if [ "$REMOVE_EXIF" = "true" ]; then
        cmd="$cmd -strip"
    fi
    
    if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
        if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
            elif [ "$MAX_WIDTH" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x>"
        else
            cmd="$cmd -resize x${MAX_HEIGHT}>"
        fi
    fi
    
    cmd="$cmd -quality $QUALITY"
    
    if [ "$CONVERT_TO_WEBP" = "true" ]; then
        local webp_file="${file%.*}.webp"
        local webp_cmd="convert \"$file\""
        
        # Remove EXIF data if enabled
        if [ "$REMOVE_EXIF" = "true" ]; then
            webp_cmd="$webp_cmd -strip"
        fi
        
        if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
            if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
                webp_cmd="$webp_cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
            elif [ "$MAX_WIDTH" != "0" ]; then
                webp_cmd="$webp_cmd -resize ${MAX_WIDTH}x>"
            else
                webp_cmd="$webp_cmd -resize x${MAX_HEIGHT}>"
            fi
        fi
        
        webp_cmd="$webp_cmd -quality $QUALITY \"$webp_file\""
        eval $webp_cmd
        # Remove EXIF data if enabled
        if [ "$REMOVE_EXIF" = "true" ]; then
            webp_cmd="$webp_cmd -strip"
        fi
        
        if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
            rm "$file"
            echo "  ✅ Converted to WebP: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$webp_file")
            return $(($original_size - $new_size))
        else
            rm "$webp_file"
            echo "  ⚠️ WebP conversion didn't reduce size, keeping original"
            return 0
        fi
    else
        cmd="$cmd \"$temp_file\""
        eval $cmd
        
        local new_size=$(get_file_size "$temp_file")
        if [ $new_size -lt $original_size ]; then
            mv "$temp_file" "$file"
            echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$file")
            return $(($original_size - $new_size))
        else
            rm "$temp_file"
            echo "  ℹ️ No optimization needed"
            return 0
        fi
    fi
}

# Function to optimize PNG
optimize_png() {
    local file=$1
    local temp_file="${file}.tmp"
    
    echo "Optimizing PNG: $file"
    
    local original_size=$(get_file_size "$file")
    
    if [ "$CONVERT_TO_WEBP" = "true" ]; then
        local webp_file="${file%.*}.webp"
        local cmd="convert \"$file\""
        
        # Remove EXIF data if enabled
        if [ "$REMOVE_EXIF" = "true" ]; then
            cmd="$cmd -strip"
        fi
        
        if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
            if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
                cmd="$cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
                elif [ "$MAX_WIDTH" != "0" ]; then
                cmd="$cmd -resize ${MAX_WIDTH}x>"
            else
                cmd="$cmd -resize x${MAX_HEIGHT}>"
            fi
        fi
        
        cmd="$cmd -quality $WEBP_QUALITY \"$webp_file\""
        eval $cmd
        
        local new_size=$(get_file_size "$webp_file")
        if [ $new_size -lt $original_size ]; then
            rm "$file"
            echo "  ✅ Converted to WebP: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$webp_file")
            return $(($original_size - $new_size))
        else
            rm "$webp_file"
            echo "  ⚠️ WebP conversion didn't reduce size, keeping original"
        fi
    fi
    
    # Use pngquant for compression
    local quality_range="${PNG_QUALITY}"
    pngquant --quality="$quality_range" --force --output "$temp_file" "$file" 2>/dev/null || cp "$file" "$temp_file"
    
    # Resize if needed
    if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
        local resize_cmd="convert \"$temp_file\""
        
        # Remove EXIF data if enabled
        if [ "$REMOVE_EXIF" = "true" ]; then
            resize_cmd="$resize_cmd -strip"
        fi
        
        if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
            resize_cmd="$resize_cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
            elif [ "$MAX_WIDTH" != "0" ]; then
            resize_cmd="$resize_cmd -resize ${MAX_WIDTH}x>"
        else
            resize_cmd="$resize_cmd -resize x${MAX_HEIGHT}>"
        fi
        resize_cmd="$resize_cmd \"${temp_file}.resized\""
        eval $resize_cmd
        mv "${temp_file}.resized" "$temp_file"
    elif [ "$REMOVE_EXIF" = "true" ]; then
        # Remove EXIF even when not resizing
        convert "$temp_file" -strip "${temp_file}.stripped"
        mv "${temp_file}.stripped" "$temp_file"
    fi
    
    # Optimize with optipng
    optipng -o2 "$temp_file" >/dev/null 2>&1 || true
    
    local new_size=$(get_file_size "$temp_file")
    if [ $new_size -lt $original_size ]; then
        mv "$temp_file" "$file"
        echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
        CHANGED_FILES+=("$file")
        return $(($original_size - $new_size))
    else
        rm "$temp_file"
        echo "  ℹ️ No optimization needed"
        return 0
    fi
}

# Function to optimize WebP
optimize_webp() {
    local file=$1
    local temp_file="${file}.tmp"
    
    echo "Optimizing WebP: $file"
    
    local original_size=$(get_file_size "$file")
    
    local cmd="convert \"$file\""
    
    # Remove EXIF data if enabled
    if [ "$REMOVE_EXIF" = "true" ]; then
        cmd="$cmd -strip"
    fi
    
    if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
        if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
            elif [ "$MAX_WIDTH" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x>"
        else
            cmd="$cmd -resize x${MAX_HEIGHT}>"
        fi
    fi
    
    cmd="$cmd -quality $WEBP_QUALITY \"$temp_file\""
    eval $cmd
    
    local new_size=$(get_file_size "$temp_file")
    if [ $new_size -lt $original_size ]; then
        mv "$temp_file" "$file"
        echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
        CHANGED_FILES+=("$file")
        return $(($original_size - $new_size))
    else
        rm "$temp_file"
        echo "  ℹ️ No optimization needed"
        return 0
    fi
}

# Process files
echo "🔍 Searching for images..."
echo ""

for pattern in $FILE_PATTERNS; do
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            SAVED=0
            
            case "${file,,}" in
                *.jpg|*.jpeg)
                    optimize_jpeg "$file"
                    SAVED=$?
                ;;
                *.png)
                    optimize_png "$file"
                    SAVED=$?
                ;;
                *.webp)
                    optimize_webp "$file"
                    SAVED=$?
                ;;
            esac
            
            if [ $SAVED -gt 0 ]; then
                OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
                TOTAL_SAVED=$((TOTAL_SAVED + SAVED))
            fi
            
            echo ""
        fi
    done < <(find . -type f -iname "$pattern" -print0)
done

# Output results
echo "=========================="
echo "📊 Summary:"
echo "  Images optimized: $OPTIMIZED_COUNT"
echo "  Total saved: $TOTAL_SAVED bytes ($(echo "scale=2; $TOTAL_SAVED / 1024" | bc) KB)"
echo ""

# Set outputs for GitHub Actions
echo "optimized-count=$OPTIMIZED_COUNT" >> $GITHUB_OUTPUT
echo "total-saved=$TOTAL_SAVED" >> $GITHUB_OUTPUT
echo "files-changed=${CHANGED_FILES[*]}" >> $GITHUB_OUTPUT

# Commit changes if any
if [ $OPTIMIZED_COUNT -gt 0 ]; then
    echo "📝 Committing changes..."
    
    # Add all changed files
    for file in "${CHANGED_FILES[@]}"; do
        git add "$file"
    done
    
    # Add skip ci if requested
    if [ "$SKIP_CI" = "true" ]; then
        COMMIT_MESSAGE="$COMMIT_MESSAGE [skip ci]"
    fi
    
    # Commit
    git commit -m "$COMMIT_MESSAGE" || true
    
    echo "✅ Changes committed successfully!"
else
    echo "ℹ️ No images were optimized, nothing to commit."
fi

echo ""
echo "🎉 Done!"
    if [ "$CONVERT_TO_WEBP" = "true" ]; then
        local webp_file="${file%.*}.webp"
        cmd="$cmd \"$webp_file\""
        eval $cmd
        
        local new_size=$(get_file_size "$webp_file")
        if [ $new_size -lt $original_size ]; then
            rm "$file"
            echo "  ✅ Converted to WebP: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$webp_file")
            return $(($original_size - $new_size))
        else
            rm "$webp_file"
            echo "  ⚠️ WebP conversion didn't reduce size, keeping original"
            return 0
        fi
    else
        cmd="$cmd \"$temp_file\""
        eval $cmd
        
        local new_size=$(get_file_size "$temp_file")
        if [ $new_size -lt $original_size ]; then
            mv "$temp_file" "$file"
            echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$file")
            return $(($original_size - $new_size))
        else
            rm "$temp_file"
            echo "  ℹ️ No optimization needed"
            return 0
        fi
    fi
}

# Function to optimize PNG
optimize_png() {
    local file=$1
    local temp_file="${file}.tmp"
    
    echo "Optimizing PNG: $file"
    
    local original_size=$(get_file_size "$file")
    
    if [ "$CONVERT_TO_WEBP" = "true" ]; then
        local webp_file="${file%.*}.webp"
        local cmd="convert \"$file\""
        
        if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
            if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
                cmd="$cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
            elif [ "$MAX_WIDTH" != "0" ]; then
                cmd="$cmd -resize ${MAX_WIDTH}x>"
            else
                cmd="$cmd -resize x${MAX_HEIGHT}>"
            fi
        fi
        
        cmd="$cmd -quality $WEBP_QUALITY \"$webp_file\""
        eval $cmd
        
        local new_size=$(get_file_size "$webp_file")
        if [ $new_size -lt $original_size ]; then
            rm "$file"
            echo "  ✅ Converted to WebP: $(($original_size - $new_size)) bytes saved"
            CHANGED_FILES+=("$webp_file")
            return $(($original_size - $new_size))
        else
            rm "$webp_file"
            echo "  ⚠️ WebP conversion didn't reduce size, keeping original"
        fi
    fi
    
    # Use pngquant for compression
    local quality_range="${PNG_QUALITY}"
    pngquant --quality="$quality_range" --force --output "$temp_file" "$file" 2>/dev/null || cp "$file" "$temp_file"
    
    # Resize if needed
    if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
        local resize_cmd="convert \"$temp_file\""
        if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
            resize_cmd="$resize_cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
        elif [ "$MAX_WIDTH" != "0" ]; then
            resize_cmd="$resize_cmd -resize ${MAX_WIDTH}x>"
        else
            resize_cmd="$resize_cmd -resize x${MAX_HEIGHT}>"
        fi
        resize_cmd="$resize_cmd \"${temp_file}.resized\""
        eval $resize_cmd
        mv "${temp_file}.resized" "$temp_file"
    fi
    
    # Optimize with optipng
    optipng -o2 "$temp_file" >/dev/null 2>&1 || true
    
    local new_size=$(get_file_size "$temp_file")
    if [ $new_size -lt $original_size ]; then
        mv "$temp_file" "$file"
        echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
        CHANGED_FILES+=("$file")
        return $(($original_size - $new_size))
    else
        rm "$temp_file"
        echo "  ℹ️ No optimization needed"
        return 0
    fi
}

# Function to optimize WebP
optimize_webp() {
    local file=$1
    local temp_file="${file}.tmp"
    
    echo "Optimizing WebP: $file"
    
    local original_size=$(get_file_size "$file")
    
    local cmd="convert \"$file\""
    
    if [ "$MAX_WIDTH" != "0" ] || [ "$MAX_HEIGHT" != "0" ]; then
        if [ "$MAX_WIDTH" != "0" ] && [ "$MAX_HEIGHT" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x${MAX_HEIGHT}>"
        elif [ "$MAX_WIDTH" != "0" ]; then
            cmd="$cmd -resize ${MAX_WIDTH}x>"
        else
            cmd="$cmd -resize x${MAX_HEIGHT}>"
        fi
    fi
    
    cmd="$cmd -quality $WEBP_QUALITY \"$temp_file\""
    eval $cmd
    
    local new_size=$(get_file_size "$temp_file")
    if [ $new_size -lt $original_size ]; then
        mv "$temp_file" "$file"
        echo "  ✅ Optimized: $(($original_size - $new_size)) bytes saved"
        CHANGED_FILES+=("$file")
        return $(($original_size - $new_size))
    else
        rm "$temp_file"
        echo "  ℹ️ No optimization needed"
        return 0
    fi
}

# Process files
echo "🔍 Searching for images..."
echo ""

for pattern in $FILE_PATTERNS; do
    while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            SAVED=0
            
            case "${file,,}" in
                *.jpg|*.jpeg)
                    optimize_jpeg "$file"
                    SAVED=$?
                    ;;
                *.png)
                    optimize_png "$file"
                    SAVED=$?
                    ;;
                *.webp)
                    optimize_webp "$file"
                    SAVED=$?
                    ;;
            esac
            
            if [ $SAVED -gt 0 ]; then
                OPTIMIZED_COUNT=$((OPTIMIZED_COUNT + 1))
                TOTAL_SAVED=$((TOTAL_SAVED + SAVED))
            fi
            
            echo ""
        fi
    done < <(find . -type f -iname "$pattern" -print0)
done

# Output results
echo "=========================="
echo "📊 Summary:"
echo "  Images optimized: $OPTIMIZED_COUNT"
echo "  Total saved: $TOTAL_SAVED bytes ($(echo "scale=2; $TOTAL_SAVED / 1024" | bc) KB)"
echo ""

# Set outputs for GitHub Actions
echo "optimized-count=$OPTIMIZED_COUNT" >> $GITHUB_OUTPUT
echo "total-saved=$TOTAL_SAVED" >> $GITHUB_OUTPUT
echo "files-changed=${CHANGED_FILES[*]}" >> $GITHUB_OUTPUT

# Commit changes if any
if [ $OPTIMIZED_COUNT -gt 0 ]; then
    echo "📝 Committing changes..."
    
    # Add all changed files
    for file in "${CHANGED_FILES[@]}"; do
        git add "$file"
    done
    
    # Add skip ci if requested
    if [ "$SKIP_CI" = "true" ]; then
        COMMIT_MESSAGE="$COMMIT_MESSAGE [skip ci]"
    fi
    
    # Commit
    git commit -m "$COMMIT_MESSAGE" || true
    
    echo "✅ Changes committed successfully!"
else
    echo "ℹ️ No images were optimized, nothing to commit."
fi

echo ""
echo "🎉 Done!"
