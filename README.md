# sdr-training-dataset

**Made in Pakistan - https://github.com/henryarkenberg/sdr-training-dataset**

A small Windows tool for pulling WAV recordings out of the
[Open Weather](https://open-weather.community) satellite archive, one file at a time
or in bulk, with a live progress bar.

The bundled `archive.csv` is the archive's index (2,595 rows, 2,474 of them with an
audio link, 2,464 unique files). The downloader reads it, lets you filter it, and
fetches the recordings you pick.

## Quick start

1. Clone or download this repository.
2. Double click **`Download-OpenWeather-Audio.bat`** (or drag `archive.csv` onto it).

Requires Windows PowerShell 5.1 (built into Windows 10/11) and an internet connection.
No installation, no admin rights, no extra modules.

## What it does

```
Open Weather Archive - audio downloader
  --------------------------------------
  Made in Pakistan - https://github.com/henryarkenberg/sdr-training-dataset
```

A filter menu, then a paged file browser:

```
Browse & download  (2,464 files)
Filter by satellite
Filter by year
Filter by date range
Filter by country / territory
Filter by contributor
Filter by record ID
Search all text fields
Clear filters (back to all records)
Settings
Exit
```

Filters stack, so `satellite -> NOAA-19` then `year -> 2025` narrows the count shown in
the header. Everything is keyboard driven: arrows to move, `Enter` to choose, `Esc` to go
back. No mouse required.

## The file browser

`Browse & download` lists the current selection **20 files per page**, each row showing
whether the file is already on disk, its number, record ID, satellite, date and filename.

```
Files in the current selection
  page 3 of 124   files 41-60 of 2,464   on disk: 4/20
  folder: C:\Users\you\Downloads\open-weather-archive\wav

> [x]     4  OW3297  NOAA-19  2025-08-31 audio-4.wav
  [x]     5  OW3296  NOAA-19  2025-08-31 audio-5.wav
  ...
  Enter = this file   a = all   p = page   s = save list   Esc = back
  Up/Down select   Left/Right page   PgUp/PgDn   Home/End
```

- **Enter** downloads only the highlighted file.
- **a** downloads the whole selection (asks first), **p** the current page, **s** saves the
  list to CSV.
- `Left/Right` change pages, `PgUp/PgDn` and `Home/End` jump around.

## Progress

Transfers go through a small compiled helper (`HttpClient`, 64 KB chunks, several workers)
that reports live byte counts, so you get an animated bar:

```
  ██████████████████████░░░░░░░░░░░░░░░░  58%   10.9 MB / 18.8 MB   19 KB/s   ETA 07:15
  2021-09-13_195549_NOAA-19_lothringer-13-halle.wav
```

Bulk downloads show an overall bar plus one mini bar per parallel transfer:

```
  ███████████████░░░░░░░░░░░░░░░░░░░░░░░  46%   1.2 GB   1.1 MB/s   ETA 12:04
  1,180 / 2,464 files   12 parallel   3 failed   elapsed 22:41
  2021-09-13_195549_NOAA-19_lothr...  █████████░░░░░   58%  10.9 MB
  audio-165.wav                       ██████░░░░░░░░   36%   5.0 MB
```

**Esc** stops a transfer cleanly; partial files are never left behind.

## Where files go

By default a `wav` folder next to the CSV (`Settings` changes it). Existing files are
skipped on later runs, so the tool is safe to run again. Files that fail (usually dead
links, HTTP 404) are retried once and then listed in `failed-downloads_<timestamp>.txt`.

Sizes vary from about 1 MB to 60 MB per recording; the full archive is roughly 50 GB, so
filter first.

## Settings

- Parallel downloads (default 12)
- Output folder
- Skip files already on disk
- Prefix filenames with the record ID
- Open the folder when finished

## Notes

- `OpenWeather-Audio-Downloader.ps1` can also be run directly:
  `powershell -ExecutionPolicy Bypass -File OpenWeather-Audio-Downloader.ps1 [path\to\archive.csv]`
- `curl.exe` and `Invoke-WebRequest` are used automatically if the compiled engine is
  unavailable (for example under a constrained PowerShell policy).
- Recordings come from [open-weather.community](https://open-weather.community); respect
  their terms when reusing the audio.

## License

No license file is included yet - add one if you want others to reuse this freely.
