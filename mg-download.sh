#!/bin/bash

# Uncomment for debug
#set -x
# Kills script if ctrl+c, without it loops continue iterating
trap "kill $(jobs -p) 2>/dev/null; exit 130" SIGINT

## Constants
# Workers proxy to bypass quota (no trailing /, USE YOUR OWN!)
PROXY="https://flat-resonance-cfdb.ililli.workers.dev"
# Large file chunk size (2GiB)
chunkSize=2147483648
# Max concurrent downloads (for folders only)
maxThreads=4
# Keep original IFS
OIFS=$IFS

# Check for required commands
commands=( aria2c base64 bc curl jq openssl truncate xxd )
for i in "${commands[@]}"; do
  until hash $i 2>/dev/null; do
    echo -e "\e[0;31mERROR\e[0m   | ${i} not found! Please install all requirements."
    ex=1
    break
  done
done
if [[ -n "${ex}" ]]; then exit 1; fi


### Important functions
# Basic info
function info {
  echo "Usage: ${0} LINK [RELATIVE/PATH/TO/FOLDER]"
  echo
  echo "mg-download.sh - weird as hell mega.nz downloader"
  echo "rev.6 for beta testing | USE AT YOUR OWN RISK!"
  echo "Please check attached README for detailed info and examples."
}

# Check for existing file and chunks
# (1: file name, 2: expected file size)
function checkFile {
  local fileName="${1}"
  local checkSize="${2}"

  # If file exists...
  if [[ -f "${1}" ]]; then
    # Check local size with remote size
    local fileSize=$(stat -c '%s' "${fileName}")
    # If bad, then error and halt.
    if [[ "${checkSize}" -ne "${fileSize}" ]]; then
      echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed. (File exists, but size mismatch: expected ${checkSize}, got ${fileSize})"
      echo -e "\e[0;31mERROR\e[0m   | Delete the offending file to continue."
      exit 1
    else
      # If good, just skip.
      echo -e "\e[0;33mNOTICE\e[0m  | ${fileName} already exists. Skipping."
      SKIP=1
    fi
  # If control file exists...
  elif [[ -f "${fileName}.control" ]]; then
    # Prepare for resume download.
    # Works like so: After each chunk is decrypted, the beginning byte position of
    # of the chunk is appended to a control file. When the download is interrupted
    # and later resumed, we will grep through the control file to see where we left
    # off, and ultimately resume from there. We also check the incomplete file size
    # in case the user interrupts the decryption, aria2 right before completion, etc.
    echo -e "\e[0;33mNOTICE\e[0m  | ${fileName} appears incomplete. Attempting resume. [BETA]"
    controlFile="${fileName}.control"
  # If control file does NOT exist but decrypted chunk does..
  elif [[ ! -f "${fileName}.control" ]] && [[ -f "${fileName}.bin" ]]; then
    # Silently remove decrypted chunk and let it continue
    # For edge case when only first chunk is done and it's mid-decrypting
    rm "${fileName}.bin"
  fi
}

# Check if response threw error
function checkCode {
  if [[ "${resBody}" =~ ^-?[0-9]+$ ]]; then
    echo -e "\e[0;31mERROR\e[0m   | Got ${resBody} from API."
    echo -e "\e[0;31mERROR\e[0m   | Check https://github.com/meganz/sdk/blob/master/include/mega/types.h#L189 for info."
    exit 1
  fi
}

# Prepare byte ranges, chunk positions, IV for large files
# (1: chunk size, 2: file size, 3: IV)
function largeFileInit {
  # Create byte ranges for download
  local range="${1}"
  local final="${2}"
  local iv="${3}"
  for ((start=0; start<=final; start+=range)); do
    end=$((start + range - 1))
    if ((end > final)); then
      end=$final
    fi
    byteRange+=("${start}-${end}")
  done

  # Arrays of each byte position
  bytePosition=( $(seq -w 0 "${range}" "${final}") )

  # AES-128-CTR's IV works as a counter for blocks read through
  # en/decryption (that's how I understand it.).
  # IV + Blocks read (byte position / 16)
  # We also need to force decimal (10#) because bash
  # tends to misidentify numbers that are padded.
  incrementIv=( $(
    for i in "${bytePosition[@]}"; do
      printf '%032s\n' $(echo "
        obase=16
        ibase=16
        ${iv} + $(echo "obase=16; $(( 10#${i} / 10#16 ))" | bc)
      " |
      bc) | tr ' ' '0'
    done
  ) )
}

# Self-explanatory
function downloadFile {
  aria2c -x2 \
    --continue \
    --quiet \
    --out "${1}" \
    "${2}"
}
function decryptFile {
  openssl enc -aes-128-ctr -d -K "${1}" -iv "${2}" -in "${3}.enc" > "${3}"
}
function decryptChunk {
  openssl enc -aes-128-ctr -d -K "${1}" -iv "${2}" -in "${3}" >> "${4}"
}

# Fetch download URL
# (1: post body, 2: api endpoint)
function fetchDownloadUrl {
  local retry
  until g="$(curl -s -XPOST -d "${1}" "${2}" | jq -er '.[].g')"; do
   sleep 1
   retry=$((++retry))
   if [[ "${retry}" -eq 5 ]]; then
     echo -e '\e[0;31mERROR\e[0m   | Failed to get URL after 5 attempts! Skipping.'
     exit 1
   fi
  done
}

# Folder file handling
# This is now its own function so we can parallelize it with &.
function folderFileDownload {
  # Body to POST to API.
  filePostBody="[{\"a\":\"g\",\"n\":\"${index}\",\"g\":1}]"
  # Putting various important variables into new ones
  # to make the code a little more readable.
  tmpSize="${fileSize[$index]}"
  tmpName="${fileAttr[$index]}"
  tmpKey="${fileKey[$index]}"
  tmpIv="${fileIv[$index]}"

  checkFile "${tmpName}" "${tmpSize}" "${index}"
  if [[ "${SKIP}" -eq 1 ]]; then return; fi

  # If file is larger than our set chunk size, then begin chunked download
  if [[ "${tmpSize}" -ge "${chunkSize}" ]]; then
    largeFileInit "${chunkSize}" "${tmpSize}" "${tmpIv}"
    echo -e "\e[0;33mCHUNKS\e[0m  | ${tmpName} (${#byteRange[@]} chunks, ${tmpSize} bytes)"

    for i in "${!byteRange[@]}"; do
      # Set chunk and temporary filenames
      chunkName="${tmpName}.${bytePosition[$i]}.enc"
      # Range to download
      chunkRange="${byteRange[$i]}"
      # End range to check if partial download matches in size
      endRange="${byteRange[$i]%%-*}"
      # Current IV position
      chunkIv="${incrementIv[$i]}"

      # Resume incomplete download if control file exists (see checkFile)
      if [[ -n "${controlFile}" ]]; then
        # Check if position was recorded in control
        grep -q "${bytePosition[$i]}" "${controlFile}"
        if [[ $? -eq 0 ]]; then
          continue
        fi
        # Compare expected size with local size, and resume accordingly
        localSize="$(stat -c '%s' "${tmpName}.bin")"
        if [[ "${localSize}" -eq "${endRange}" ]]; then
          echo -e "\e[0;33mCHUNKS\e[0m  | ${tmpName} (${i}/${#byteRange[@]} chunks complete. Resuming.)"
          unset controlFile
        # If file was interrupted during decryption (local larger than expected), truncate and resume.
        elif [[ "${localSize}" -gt "${endRange}" ]]; then
          echo -e "\e[0;33mNOTICE\e[0m  | ${tmpName} (Size mismatch, ${localSize} larger than ${endRange})"
          echo -e "\e[0;33mNOTICE\e[0m  | I'm assuming this file was interrupted mid-decryption. Truncating and resuming."
          truncate -c -s "${endRange}" "${tmpName}.bin"
          echo -e "\e[0;33mCHUNKS\e[0m  | ${tmpName} (${i}/${#byteRange[@]} chunks complete. Resuming.)"
          unset controlFile
        else
          # I don't necessarily know if we need this, but it will stay.
          echo -e "\e[0;31mERROR\e[0m   | ${tmpName} failed. (Size mismatch, expected ${endRange}, got $(localSize})"
          echo -e "\e[0;31mERROR\e[0m   | Unable to resume. Delete the offending file(s) to continue."
          # TODO make report file/log maybe? or just delete.
          exit 1
        fi
      fi

      # We need to fetch a new URL every time due to 60s expiry
      # Now this has error checking + retries. yay.
      local retry
      echo -e "\e[0;33mDOWNLOAD\e[0m| [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${tmpName}"
      until fetchDownloadUrl "${filePostBody}" "${API}"
            url="${PROXY}/${g}/${byteRange[$i]}"
            downloadFile "${chunkName}" "${url}"; do
        retCode=$?
        retry=$((++retry))
        if [[ $retCode -eq 7 ]]; then
          return
        elif [[ $retry -eq 5 ]]; then
          echo -e "\e[0;31mERROR\e[0m   | ${tmpName} failed after 5 attempts. Skipping. (TODO: add file cleanup)"
          return 1
        elif [[ $retCode -ne 0 ]]; then
          echo -e "\e[0;31mERROR\e[0m   | ${tmpName} failed with code ${retCode}! Retrying. (${retry}/5)"
        fi
      done
      unset retry

      echo -e "DECRYPT | [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${tmpName}"
      decryptChunk "${tmpKey}" "${chunkIv}" "${chunkName}" "${tmpName}.bin"
      # TODO: error check?
      rm "${chunkName}"
      echo "${bytePosition[$i]}" >> "${tmpName}.control"
      echo -e "\e[0;32mDONE\e[0m    | [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${tmpName}"
    done
    unset byteRange bytePosition incrementIv
    mv "${tmpName}.bin" "${tmpName}"
    rm "${tmpName}.control"
    echo -e "\e[0;32mDONE\e[0m    | ${tmpName}"
  # Otherwise, just do simple download.
  else
    echo -e "\e[0;33mDOWNLOAD\e[0m| ${tmpName}"
    local retry
    until fetchDownloadUrl "${filePostBody}" "${API}"
          url="${PROXY}/${g}"
          downloadFile "${tmpName}.enc" "${url}"; do
      retCode=$?
      retry=$((++retry))
      if [[ $retCode -eq 7 ]]; then
        return
      elif [[ $retry -eq 5 ]]; then
        echo -e "\e[0;31mERROR\e[0m   | ${tmpName} failed after 5 attempts. Skipping. (TODO: add file cleanup)"
        return 1
      elif [[ $retCode -ne 0 ]]; then
        echo -e "\e[0;31mERROR\e[0m   | ${tmpName} failed with code ${retCode}! Retrying. (${retry}/5)"
      fi
    done
    unset retry

    echo "DECRYPT | ${tmpName}"
    decryptFile "${tmpKey}" "${tmpIv}" "${tmpName}"
    rm "${tmpName}.enc"
    echo -e "\e[0;32mDONE\e[0m    | ${tmpName}"
  fi
}

# Basic sanity check
if [[ -z "${1}" ]]; then
  echo -e "\e[0;31mERROR\e[0m   | No link specified.\n"
  info
  exit 2
fi

# Split link to id and key
ID=$(echo "$1" | cut -f1 -d# | cut -f5 -d/)
KEY=$(echo "$1" | cut -f2 -d# | cut -f1 -d/ | tr '\-_' '+/')

# Stupid sanity check
if [[ -z "${ID}" ]] || [[ "${KEY}" == *":"* ]] || [[ -z "${KEY}" ]]; then
  echo "\e[0;31mERROR\e[0m   | Bad URL."
  exit 1
fi

# Check what type of link we're doing + okay-ish sanity check
linkType=$(echo "${1}" | cut -f4 -d/)
if [[ "${linkType}" == "file" ]]; then
  # Set API url and POST body
  API="https://g.api.mega.co.nz/cs"
  postBody="[{\"a\":\"g\",\"p\":\"${ID}\",\"g\":1}]"
elif [[ "${linkType}" == "folder" ]]; then
  # Set API url and POST body
  API="https://g.api.mega.co.nz/cs?n=${ID}"
  postBody='[{"a":"f","c":1,"ca":1,"r":1}]'

  # Check for subfolder or file inside link, error on former.
  F6=$(echo "${1}" | cut -f6 -d/)
  if [[ -n "${F6}" ]]; then
    if [[ "${F6}" == "file" ]]; then
      F7=$(echo "${1}" | cut -f7 -d/)
      echo "\e[0;33mNOTICE\e[0m  | File detected in folder link. Downloading."
    elif [[ "${F6}" == "folder" ]]; then
      echo "\e[0;31mERROR\e[0m   | Subfolder downloading by link isn't supported."
      echo "\e[0;31mERROR\e[0m   | Please specify it as a path like so:"
      echo "\e[0;31mERROR\e[0m   | ./${0} LINK \"Relative/path/without/trailing/slash\""
      exit 1
    fi
  fi
else
  # TODO: Handle legacy urls.
  echo "\e[0;31mERROR\e[0m   | Can't determine whether link is a file or a folder."
  echo "\e[0;31mERROR\e[0m   | Legacy URLs are not supported, sorry."
  exit 1
fi

# If link is folder and path is set, set search variable
if [[ -n "${2}" ]] && [[ "${linkType}" == "folder" ]]; then
  relPath="${2}"
  echo "Searching ${relPath} and downloading any match..."
elif [[ -n "${2}" ]] && [[ "${linkType}" == "file" ]] || [[ "${F6}" == "file" ]]; then
  echo "Warning: No point in having a path set, you're downloading a file!"
fi

## Big ass if statement to handle file links and folder links.
# File download
# We're only handling one file so we can not parallelize it.
if [[ "${linkType}" == "file" ]]; then
  # Get full key.
  hexKey=$(echo "${KEY}" | base64 -d 2>/dev/null | xxd -pu -c32)
  hexKey="${hexKey^^}"
  # Get AES decryption key with XOR magic (read page 24 of whitepaper)
  fileKey=$(
    printf '%016X' \
    $(( 0x${hexKey:0:16} ^ 0x${hexKey:32:16} )) \
    $(( 0x${hexKey:16:16} ^ 0x${hexKey:48:16} ))
  )
  # Get AES IV (nonce)
  fileIv="${hexKey:32:16}0000000000000000"

  # Send API request
  resBody=$(curl -s --compressed -XPOST -d "${postBody}" "${API}")
  checkCode

  # File metadata (jq to delimited string for decryption)
  # .at (attributes [file name]), .s (size)
  # (b64c function: clean url-safe base64 to standard base64)
  fileMetadata=( $(
    echo "${resBody}" |
    jq -r '
      def b64c: gsub("-"; "+") | gsub("_"; "/");
      .[] |
      (.at | b64c) + "@" +
      (.s | tostring)
    '
  ) )

  # Decrypt metadata
  fileName=$(
    echo "${fileMetadata}" |
    cut -f1 -d@ |
    base64 -d 2>/dev/null |
    openssl enc -aes-128-cbc -d -K "${fileKey}" -iv 0 -nopad 2>/dev/null |
    tr -d '\0' |
    cut -c5- |
    jq -r .n
  )
  fileSize=$( echo "${fileMetadata}" | cut -f2 -d@ )

  # Check for existing file, chunks
  checkFile "${fileName}" "${fileSize}" "${ID}"
  if [[ "${SKIP}" -eq 1 ]]; then exit; fi

  # Big file download
  if [[ "${fileSize}" -gt "${chunkSize}" ]]; then
    # byteRange, bytePosition, incrementIv
    largeFileInit "${chunkSize}" "${fileSize}" "${fileIv}"
    echo -e "\e[0;33mCHUNKS\e[0m  | ${fileName} (${#byteRange[@]} chunks, ${fileSize} bytes)"

    # Iterate over arrays to process each chunk.
    for i in "${!byteRange[@]}"; do
      # Chunk filename
      chunkName="${fileName}.${bytePosition[$i]}.enc"
      # Range to download
      chunkRange="${byteRange[$i]}"
      # End range to check if partial file matches with sum of finished chunks
      endRange="${byteRange[$i]%%-*}"
      # Current IV position
      chunkIv="${incrementIv[$i]}"

      # Resume incomplete download if control file exists (see checkFile)
      if [[ -n "${controlFile}" ]]; then
        # Check if position was recorded in control
        grep -q "${bytePosition[$i]}" "${controlFile}"
        if [[ $? -eq 0 ]]; then
          continue
        fi
        # Compare expected size with local size, and resume accordingly
        localSize="$(stat -c '%s' "${fileName}.bin")"
        if [[ "${localSize}" -eq "${endRange}" ]]; then
          echo -e "\e[0;33mCHUNKS\e[0m  | ${fileName} (${i}/${#byteRange[@]} chunks complete. Resuming.)"
          unset controlFile
        # If file was interrupted during decryption (local larger than expected), truncate and resume.
        elif [[ "${localSize}" -gt "${endRange}" ]]; then
          echo -e "\e[0;33mNOTICE\e[0m  | ${fileName} (Size mismatch, ${localSize} larger than ${endRange})"
          echo -e "\e[0;33mNOTICE\e[0m  | I'm assuming this file was interrupted mid-decryption. Truncating and resuming."
          truncate -c -s "${endRange}" "${fileName}.bin"
          echo -e "\e[0;33mCHUNKS\e[0m  | ${fileName} (${i}/${#byteRange[@]} chunks complete. Resuming.)"
          unset controlFile
        else
          # I don't necessarily know if we need this, but it will stay.
          echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed. (Size mismatch, expected ${endRange}, got $(localSize})"
          echo -e "\e[0;31mERROR\e[0m   | Unable to resume. Delete the offending file(s) to continue."
          # TODO make report file/log maybe? or just delete.
          exit 1
        fi
      fi


      # We need to fetch a new URL every time due to 60s expiry
      echo -e "\e[0;33mDOWNLOAD\e[0m| [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${fileName}"
      until fetchDownloadUrl "${postBody}" "${API}"
            url="${PROXY}/${g}/${byteRange[$i]}"
            downloadFile "${chunkName}" "${url}"; do
        retCode=$?
        retry=$((++retry))
        if [[ $retry -eq 5 ]]; then
          echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed after 5 attempts. Exiting."
          exit 1
        elif [[ $retCode -ne 0 ]]; then
          echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed with code ${retCode}! Retrying. (${retry}/5)"
        fi
      done
      unset retry

      echo -e "DECRYPT | [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${fileName}"
      decryptChunk "${fileKey}" "${chunkIv}" "${chunkName}" "${fileName}.bin"
      # TODO: Error handling, here and everything above and below.
      rm "${chunkName}"
      echo "${bytePosition[$i]}" >> "${fileName}.control"
      echo -e "\e[0;32mDONE\e[0m    | [Chunk $(( $i + 1 ))/${#byteRange[@]}] ${fileName}"
    done
    mv "${fileName}.bin" "${fileName}"
    rm "${fileName}.control"
    echo -e "\e[0;32mDONE\e[0m    | ${fileName}"
  else
  # Small file download
    echo -e "\e[0;33mDOWNLOAD\e[0m| ${fileName}"
    until fetchDownloadUrl "${postBody}" "${API}"
          fileUrl="${PROXY}/${g}"
          downloadFile "${fileName}.enc" "${fileUrl}"; do
      retCode=$?
      retry=$((++retry))
      if [[ $retry -eq 5 ]]; then
        echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed after 5 attempts. Exiting."
        exit 1
      elif [[ $retCode -ne 0 ]]; then
        echo -e "\e[0;31mERROR\e[0m   | ${fileName} failed with code ${retCode}! Retrying. (${retry}/5)"
      fi
    done
    unset retry

    echo "DECRYPT | ${fileName}"
    decryptFile "${fileKey}" "${fileIv}" "${fileName}"
    rm "${fileName}.enc"
    echo -e "\e[0;32mDONE\e[0m    | ${tmpName}"
  fi
else
  # Folder download
  # Key to hex
  fKey=$(echo "${KEY}" | base64 -d 2>/dev/null | xxd -pu)

  # Send API request
  resBody=$(curl -s --compressed -XPOST -d "${postBody}" "${API}")
  checkCode

  # Create array of folders as delimited strings containing:
  # .h (handle/id), .a (attributes [name]), .k (key) .p (parent handle)
  # (b64c function: clean url-safe base64 to standard base64)
  folderArray=( $(
    echo "${resBody}" |
    jq -r '
      def b64c: gsub("-"; "+") | gsub("_"; "/");
      .[].f[] |
      select(.t==1) |
        .h + "@" +
        (.a | b64c) + "@" +
        (.k | split(":")[1] | b64c) + "@" +
        .p
    '
  ) )
  # same as above but for files + .s (size)
  fileArray=( $(
    echo "${resBody}" |
    jq -r '
      def b64c: gsub("-"; "+") | gsub("_"; "/");
      .[].f[] |
      select(.t==0) |
        .h + "@" +
        (.a | b64c) + "@" +
        (.k | split(":")[1] | b64c) + "@" +
        .p + "@" +
        (.s | tostring)
    '
  ) )

  if [[ ${#fileArray[@]} -ge 200 ]]; then
    echo -e "\e[0;33mNOTICE\e[0m  | Large folder. This may take some time to parse... (${#fileArray[@]} files)"
  fi

  # Declare folder associative arrays
  declare -A folderAttr
  declare -A folderKey
  declare -A folderParent

# TODO: Rename all instances of hash to handle
  # Populate arrays
  for i in "${folderArray[@]}"; do
    # Set delimiter and read each entry
    IFS="@"
    read -r h a k p < <(echo "${i}")
    IFS=$OIFS

    # First entry will always be the root folder, so we
    # force the parent to be null for the jq script.
    if [[ -z $root ]]; then
      p="null"
    fi
    root=1

    # Assign to arrays
    folderHash+=( "${h}" )
    folderAttr+=( ["${h}"]="${a}" )
    folderKey+=( ["${h}"]="${k}" )
    folderParent+=( ["${h}"]="${p}" )
  done

  # Decrypt folder metadata
  for i in "${folderHash[@]}"; do
    # Folder decryption keys
    # AES-128-ECB
    folderKey["${i}"]=$(
      echo "${folderKey[$i]}" |
      base64 -d 2>/dev/null |
      openssl enc -aes-128-ecb -d -K "${fKey}" -nopad 2>/dev/null |
      xxd -pu
    )

    # Decrypt attributes and get name
    # AES-128-CBC with IV of 0
    folderAttr["${i}"]=$(
      echo "${folderAttr[$i]}" |
      base64 -d 2>/dev/null |
      openssl enc -aes-128-cbc -d -K "${folderKey[$i]}" -iv 0 -nopad 2>/dev/null |
      cut -c5- |
      tr -d '\0' |
      jq -r .n
    )

    # Create JSON to array to later slurp with jq.
    # I'm not a fan of this, but it is acceptable, I guess.
    jsonToSlurp+=( "{\"hash\":\"$i\",\"parent\":$(if [[ ${folderParent[$i]} == "null" ]]; then echo null; else echo \"${folderParent[$i]}\"; fi),\"type\":1,\"name\":\"${folderAttr[$i]}\"}")
  done

  # Get root directory
  rootDir="$(echo "${jsonToSlurp[0]}" | jq -r .name)"

  # Now to do it all over again! (for files)
  # Declare file associative arrays
  declare -A fileAttr
  declare -A fileKey
  declare -A fileIv
  declare -A fileParent
  declare -A fileSize

  # Populate arrays
  for i in "${fileArray[@]}"; do
    # Set delimiter and read each entry
    IFS="@"
    read -r h a k p s < <(echo "${i}")
    IFS=$OIFS

    # Assign to arrays
    fileHash+=( "${h}" )
    fileAttr["${h}"]="${a}"
    fileKey["${h}"]="${k}"
    fileParent["${h}"]="${p}"
    fileSize["${h}"]="${s}"
  done

  # If file in folder link is set, reset hash array to just that file.
  if [[ -n "${F7}" ]]; then
    unset fileHash
    fileHash="${F7}"
  fi

  # Decrypt file metadata and assign key and IV
  for i in "${fileHash[@]}"; do
    # Decrypt full file key
    # AES-128-ECB
    fileKey["${i}"]=$(
      echo "${fileKey[$i]}" |
      base64 -d 2>/dev/null |
      openssl enc -aes-128-ecb -d -K "${fKey}" -nopad 2>/dev/null |
      xxd -pu -c32
    )
    # Get IV (nonce) and make uppercase for bc (assuming file is large)
    fileIv["${i}"]="${fileKey[$i]:32:16}0000000000000000"
    fileIv["${i}"]="${fileIv[$i]^^}"
    # XOR full key to get actual decryption key (also uppercase cuz why not)
    fileKey["${i}"]=$(
      printf '%016X' \
      $(( 0x${fileKey[$i]:0:16} ^ 0x${fileKey[$i]:32:16} )) \
      $(( 0x${fileKey[$i]:16:16} ^ 0x${fileKey[$i]:48:16} ))
    )

    # Decrypt attributes and get name
    # AES-128-CBC with IV of 0
    fileAttr["${i}"]=$(
      echo "${fileAttr[$i]}" |
      base64 -d 2>/dev/null |
      openssl enc -aes-128-cbc -d -K "${fileKey[$i]}" -iv 0 -nopad 2>/dev/null |
      cut -c5- |
      tr -d '\0' |
      jq -r .n
    )

    # Create and add JSON to array to slurp with jq later
    jsonToSlurp+=( "{\"hash\":\"$i\",\"parent\":\"${fileParent[$i]}\",\"type\":0,\"name\":\"${fileAttr[$i]}\"}")
  done

  # Parse JSON to full file listing (handle:full/path) and put into array
  IFS=$'\n'
  theList=( $(
    echo "${jsonToSlurp[@]}" |
    jq -s -r '
      INDEX(.hash) as $entries |
      def get_path(hash):
        if hash == null then []
        else
          $entries[hash] as $e |
          get_path($e.parent) + [$e.name]
        end;
      .[] |
      select(.type == 0) | .hash + ":" +
      (get_path(.parent) + [.name] | join("/"))
    '
  ) )
  IFS=$OIFS

  # If a path was set, we search for any matches for it,
  # then reset the listing and hash arrays to download
  # only what was found.
  if [[ -n "${relPath}" ]]; then
    for i in "${theList[@]}"; do
      if [[ "${i}" == *":${rootDir}/${relPath}/"* ]]; then
        searchList+=( "${i}" )
      fi
    done
    if [[ -z "${searchList}" ]]; then
      echo -e "\e[0;31mERROR\e[0m   | No matches found!"
      exit 1
    fi
    # Reassign listing array to just results
    theList=( "${searchList[@]}" )
    echo -e "\e[0;33mNOTICE\e[0m  | Found ${#theList[@]} match(es)!"
  fi

  # Iterate through array to set fileAttr to have full path name
  for i in "${theList[@]}"; do
    IFS=":"
    read -r h n < <(echo "${i}")
    IFS=$OIFS
    # Narrow down hash array after search
    if [[ -n "${relPath}" ]]; then
      unset fileHash
      fileHash=( "${h}" )
    fi
    fileAttr["${h}"]="${n}"
  done

  # Begin the downloading process
  for index in "${fileHash[@]}"; do
    # We will use jobs to see how many subshells are going, and if they are
    # equal to $maxThreads, then we wait for one to finish before we move on.
    if [[ $(jobs -r -p | wc -l) -ge $maxThreads ]]; then wait -n; fi
    sleep 0.3
    folderFileDownload &
  done
fi

wait
echo -e "\e[0;33mNOTICE\e[0m  | Done!"
# todo: check for failed files
