#!/bin/bash
# Re-cuts the website's film, preview loop, clips and posters from the 4K master.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
master="$root/build/DemoVideo/kinara-film-4k.mp4"
media="$root/website-kinara/public/media"
q="-loglevel error -y"
x264="-c:v libx264 -preset slow -pix_fmt yuv420p -profile:v high -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart"
# The film: 1440p60 with sound. Cloudflare Pages serves files up to 25 MiB, so it must stay
# under that; CRF 21 leaves about 2 MiB to spare and looks the same as 20 (SSIM 0.998).
ffmpeg $q -i "$master" -vf "scale=2560:1440:flags=lanczos" $x264 -crf "${FILM_CRF:-21}" -g 120 -c:a aac -b:a 192k "$media/kinara-film.mp4"
film_bytes="$(stat -f %z "$media/kinara-film.mp4")"
if (( film_bytes >= 25 * 1048576 )); then
    printf 'The film is %s bytes, over Cloudflare Pages'"'"' 25 MiB limit. Run again with a higher FILM_CRF.\n' "$film_bytes" >&2
    exit 1
fi
# A clip: start, duration, name, size, fps, crf.
clip() { ffmpeg $q -ss "$1" -t "$2" -i "$master" -an -vf "fps=$5,scale=${4}:flags=lanczos" $x264 -crf "$6" "$media/$3"; }
clip 14.45 7.1 clips/corners.mp4 1280:720 30 24
clip 21.65 9.5 clips/clipboard.mp4 1280:720 30 24
clip 32.42 8.3 clips/glow.mp4 1280:720 30 24
clip 40.85 9.5 clips/mixer.mp4 1280:720 30 24
clip 57.65 9.5 clips/feel.mp4 1280:720 30 24
# "It knows a palm from a finger": every app's own edges, then the palm.
ffmpeg $q -ss 50.45 -t 7.1 -i "$master" -ss 75.62 -t 1.15 -i "$master" -an -filter_complex "[0:v]fps=30,scale=1280:720:flags=lanczos[a];[1:v]fps=30,scale=1280:720:flags=lanczos[b];[a][b]concat=n=2:v=1[v]" -map "[v]" $x264 -crf 24 "$media/clips/aware.mp4"
# The cinema section's silent loop: the light scene.
clip 32.42 8.3 film-preview.mp4 1600:900 30 23
# Posters.
still() { ffmpeg $q -ss "$1" -i "$master" -frames:v 1 -vf "scale=${3}:flags=lanczos" -q:v 3 "$media/$2"; }
still 8.9 film-poster.jpg 2560:1440
still 32.43 film-preview.jpg 1600:900
still 18.3 clips/corners.jpg 1280:720
still 27.0 clips/clipboard.jpg 1280:720
still 34.9 clips/glow.jpg 1280:720
still 46.0 clips/mixer.jpg 1280:720
still 62.7 clips/feel.jpg 1280:720
still 54.4 clips/aware.jpg 1280:720
ls -la "$media"/*.mp4 "$media"/clips/*.mp4 | awk '{printf "%8.2f MB  %s\n", $5/1048576, $9}'
