#!/bin/zsh

# EXIF Date Fixer Script
# This script fixes EXIF dates for photos and videos based on filename patterns or folder structure

# Check if exiftool is installed
if ! command -v exiftool &> /dev/null; then
    echo "Error: exiftool not found. Please install exiftool first."
    echo "On macOS: brew install exiftool"
    echo "On Ubuntu/Debian: sudo apt-get install libimage-exiftool-perl"
    exit 1
fi

# Configuration
ROOT_DIR="change_me"
YEAR_DIR="$1"
DRY_RUN="false"

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$YEAR_DIR" ]; then
    echo "Usage: $0 <year> [--dry-run]"
    echo "Example: $0 2024 --dry-run"
    exit 1
fi

if [ ! -d "$ROOT_DIR" ]; then
    echo "Error: Root directory $ROOT_DIR does not exist"
    exit 1
fi

# Change to the target directory
cd "$ROOT_DIR/$YEAR_DIR" || {
    echo "Error: Cannot access directory $ROOT_DIR/$YEAR_DIR"
    exit 1
}

echo "EXIF Date Fixer Script"
echo "====================="
echo "Base directory: $ROOT_DIR"
if [ -n "$YEAR_DIR" ]; then
    echo "Year directory: $YEAR_DIR"
fi
echo "Working in: $(pwd)"
echo "Dry run: $DRY_RUN"
echo ""

# Counter files for statistics
SUCCESS_FILE="/tmp/exif_success_$$"
FAILED_FILE="/tmp/exif_failed_$$"
SKIPPED_FILE="/tmp/exif_skipped_$$"
TOTAL_FILE="/tmp/exif_total_$$"

# Initialize counters
echo "0" > "$SUCCESS_FILE"
echo "0" > "$FAILED_FILE"
echo "0" > "$SKIPPED_FILE"
echo "0" > "$TOTAL_FILE"

# Helper functions for counter management
increment_counter() {
    local file="$1"
    local current=$(cat "$file")
    echo $((current + 1)) > "$file"
}

get_counter() {
    cat "$1"
}

# Function to process a single file with proper priority logic
process_single_file() {
    local file="$1"
    local filename=$(basename "$file")
    local dir_path=$(dirname "$file")
    local date_str=""
    local source_info=""
    
    increment_counter "$TOTAL_FILE"
    
    # Check actual file type and fix wrong extensions
    local file_type=$(file -b "$file" 2>/dev/null)
    local is_image=false
    local is_video=false
    local correct_extension=""
    local current_file="$file"
    
    if [[ $file_type =~ JPEG ]]; then
        is_image=true
        correct_extension="jpg"
    elif [[ $file_type =~ PNG ]]; then
        is_image=true
        correct_extension="png"
    elif [[ $file_type =~ WebP ]]; then
        is_image=true
        correct_extension="webp"
    elif [[ $file_type =~ TIFF ]]; then
        is_image=true
        correct_extension="tiff"
    elif [[ $file_type =~ GIF ]]; then
        is_image=true
        correct_extension="gif"
    elif [[ $file_type =~ (MP4|ISO.*MP4) ]]; then
        is_video=true
        correct_extension="mp4"
    elif [[ $file_type =~ (QuickTime|MOV|data) ]]; then
        is_video=true
        correct_extension="mov"
    else
        echo "Пропускаю $file - неподдерживаемый тип файла: $file_type"
        increment_counter "$SKIPPED_FILE"
        return
    fi
    
    # Check if file extension matches actual type
    local current_extension=$(echo "${filename##*.}" | tr '[:upper:]' '[:lower:]')
    if [[ "$current_extension" != "$correct_extension" ]]; then
        local new_filename="${filename%.*}.$correct_extension"
        local new_file="$(dirname "$file")/$new_filename"
        
        echo "Переименовываю $file -> $new_filename (тип файла: $file_type)"
        
        if [ "$DRY_RUN" != "true" ]; then
            if mv "$file" "$new_file" 2>/dev/null; then
                current_file="$new_file"
                filename="$new_filename"
                echo "✓ Файл переименован успешно"
            else
                echo "✗ Ошибка переименования файла"
                increment_counter "$FAILED_FILE"
                return
            fi
        else
            current_file="$new_file"
            filename="$new_filename"
            echo "✓ Файл будет переименован (dry run)"
        fi
    fi
    
    # Update file variable for further processing
    file="$current_file"
    
    # Check if file already has date metadata
    if [ "$is_video" = "true" ]; then
        if exiftool -q -CreateDate -MediaCreateDate -TrackCreateDate -s -s -s "$file" | grep -q "^[0-9]\{4\}:[0-9]\{2\}:[0-9]\{2\}"; then
            echo "Пропускаю $file - уже имеет видео метаданные"
            increment_counter "$SKIPPED_FILE"
            return
        fi
    elif [ "$is_image" = "true" ]; then
        if exiftool -q -DateTimeOriginal -s -s -s "$file" | grep -q "^[0-9]\{4\}:[0-9]\{2\}:[0-9]\{2\}"; then
            echo "Пропускаю $file - уже имеет EXIF дату"
            increment_counter "$SKIPPED_FILE"
            return
        fi
    fi
    
    # Priority 1: Extract date from filename patterns
    if [[ $filename =~ IMG_([0-9]{8})_([0-9]{6})\. ]]; then
        # IMG_YYYYMMDD_HHMMSS pattern
        local date_part="${match[1]}"
        local time_part="${match[2]}"
        local year=${date_part:0:4}
        local month=${date_part:4:2}
        local day=${date_part:6:2}
        local hour=${time_part:0:2}
        local minute=${time_part:2:2}
        local second=${time_part:4:2}
        date_str="$year:$month:$day $hour:$minute:$second"
        source_info="ИЗ НАЗВАНИЯ ФАЙЛА IMG_YYYYMMDD_HHMMSS"
        
    elif [[ $filename =~ ([0-9]{4})[_-]([0-9]{2})[_-]([0-9]{2}) ]]; then
        # YYYY-MM-DD or YYYY_MM_DD pattern
        local year="${match[1]}"
        local month="${match[2]}"
        local day="${match[3]}"
        date_str="$year:$month:$day 12:00:00"
        source_info="ИЗ НАЗВАНИЯ ФАЙЛА YYYY-MM-DD"
        
    elif [[ $filename =~ ([0-9]{2})-([0-9]{2})-([0-9]{2})\ ([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
        # YY-MM-DD HH-MM-SS pattern
        local year="20${match[1]}"
        local month="${match[2]}"
        local day="${match[3]}"
        local hour="${match[4]}"
        local minute="${match[5]}"
        local second="${match[6]}"
        # Validate date components
        if [[ $((month)) -ge 1 && $((month)) -le 12 && $((day)) -ge 1 && $((day)) -le 31 && $((hour)) -ge 0 && $((hour)) -le 23 && $((minute)) -ge 0 && $((minute)) -le 59 && $((second)) -ge 0 && $((second)) -le 59 ]]; then
            date_str="$year:$month:$day $hour:$minute:$second"
            source_info="ИЗ НАЗВАНИЯ ФАЙЛА YY-MM-DD HH-MM-SS"
        fi
        
    elif [[ $filename =~ P_([0-9]{8})_([0-9]{6}) ]]; then
        # P_YYYYMMDD_HHMMSS pattern
        local date_part="${match[1]}"
        local time_part="${match[2]}"
        local year=${date_part:0:4}
        local month=${date_part:4:2}
        local day=${date_part:6:2}
        local hour=${time_part:0:2}
        local minute=${time_part:2:2}
        local second=${time_part:4:2}
        date_str="$year:$month:$day $hour:$minute:$second"
        source_info="ИЗ НАЗВАНИЯ ФАЙЛА P_YYYYMMDD_HHMMSS"
        
    elif [[ $filename =~ ([0-9]{8})_([0-9]{6})_lmc ]]; then
        # YYYYMMDD_HHMMSS_lmc pattern
        local date_part="${match[1]}"
        local time_part="${match[2]}"
        local year=${date_part:0:4}
        local month=${date_part:4:2}
        local day=${date_part:6:2}
        local hour=${time_part:0:2}
        local minute=${time_part:2:2}
        local second=${time_part:4:2}
        date_str="$year:$month:$day $hour:$minute:$second"
        source_info="ИЗ НАЗВАНИЯ ФАЙЛА YYYYMMDD_HHMMSS_LMC"
        
    elif [[ $filename =~ (^|[^0-9])([0-9]{8})([^0-9]|$) ]]; then
        # YYYYMMDD pattern (8 digits not part of a longer number)
        local date_part="${match[2]}"
        local year=${date_part:0:4}
        local month=${date_part:4:2}
        local day=${date_part:6:2}
        # Validate the extracted date components
        if [[ $year -ge 1900 && $year -le 2100 && $month -ge 1 && $month -le 12 && $day -ge 1 && $day -le 31 ]]; then
            date_str="$year:$month:$day 12:00:00"
            source_info="ИЗ НАЗВАНИЯ ФАЙЛА YYYYMMDD"
        fi
        
    elif [[ $filename =~ ([0-9]{10,13}) ]]; then
        # Unix timestamp pattern
        local timestamp="${match[1]}"
        if [ ${#timestamp} -eq 13 ]; then
            timestamp=$((timestamp / 1000))
        fi
        date_str=$(date -r "$timestamp" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
        if [ $? -eq 0 ]; then
            source_info="ИЗ НАЗВАНИЯ ФАЙЛА TIMESTAMP"
        fi
    fi
    
    # Priority 2: If no date from filename, check if in month folder
    if [ -z "$date_str" ] && [[ $dir_path =~ \./([0-9]{1,2})$ ]]; then
        local month=$(printf "%02d" "${match[1]}")
        local year="$YEAR_DIR"
        date_str="$year:$month:01 12:00:00"
        source_info="ИЗ ПАПКИ МЕСЯЦА: $month"
    fi
    
    # Priority 3: If no date from filename or month folder, use year folder
    if [ -z "$date_str" ]; then
        local year="$YEAR_DIR"
        date_str="$year:06:01 12:00:00"
        source_info="ИЗ ПАПКИ ГОДА: $year"
    fi
    
    echo "Обрабатываю $file: устанавливаю дату $date_str [$source_info]"
    
    # Apply the date
    if [ "$DRY_RUN" != "true" ]; then
        if [ "$is_video" = "true" ]; then
            # For videos, set video-specific date fields
            if exiftool -q -overwrite_original \
                "-CreateDate=$date_str" \
                "-ModifyDate=$date_str" \
                "-MediaCreateDate=$date_str" \
                "-TrackCreateDate=$date_str" \
                "$file" 2>/dev/null; then
                echo "✓ $file - успешно обработан"
                increment_counter "$SUCCESS_FILE"
            else
                echo "✗ $file - ошибка обработки (видео)"
                increment_counter "$FAILED_FILE"
            fi
        elif [ "$is_image" = "true" ]; then
            # For images, set standard EXIF fields
            if exiftool -q -overwrite_original \
                "-DateTimeOriginal=$date_str" \
                "-CreateDate=$date_str" \
                "-ModifyDate=$date_str" \
                "$file" 2>/dev/null; then
                echo "✓ $file - успешно обработан"
                increment_counter "$SUCCESS_FILE"
            else
                echo "✗ $file - ошибка обработки (изображение)"
                increment_counter "$FAILED_FILE"
            fi
        fi
    else
        echo "✓ $file - будет обработан (dry run)"
        increment_counter "$SUCCESS_FILE"
    fi
}

echo "Starting EXIF date fixing process..."
echo ""

if [ "$DRY_RUN" = "true" ]; then
    echo "DRY RUN MODE - No files will be modified"
    echo ""
fi

# Process all supported files recursively
find . -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o \
                 -name "*.png" -o -name "*.PNG" -o -name "*.webp" -o -name "*.WEBP" -o \
                 -name "*.mov" -o -name "*.MOV" -o -name "*.mp4" -o -name "*.MP4" \) | while read -r file; do
    process_single_file "$file"
done

# Print final statistics
echo ""
echo "Processing complete!"
echo "==================="
echo "Total files processed: $(get_counter "$TOTAL_FILE")"
echo "Successfully updated: $(get_counter "$SUCCESS_FILE")"
echo "Failed to update: $(get_counter "$FAILED_FILE")"
echo "Skipped (already have dates): $(get_counter "$SKIPPED_FILE")"

# Cleanup temporary files
rm -f "$SUCCESS_FILE" "$FAILED_FILE" "$SKIPPED_FILE" "$TOTAL_FILE"

echo ""
echo "Verification commands:"
echo "exiftool -r -DateTimeOriginal -s -s -s . | head -20"
echo "exiftool -r -CreateDate -s -s -s . | head -20"