# Generating App Icons

The app icon works by using a high-resolution PNG source to generate a standard
macOS `.icns` file.

## Prerequisites

- **Source Image**: A high-resolution PNG (at least 1024x1024) located at
  `Media/icon_original.png`.
- **Tools**: macOS standard tools `sips` (image processing) and `iconutil`.

## Step-by-Step Guide

If you need to regenerate the icons (e.g., after changing the source image):

1. **Create the Iconset Structure:** Create a temporary directory with the
   `.iconset` extension.
   ```bash
   mkdir Media/AppIcon.iconset
   ```

2. **Resize Images:** Use `sips` to generate all required sizes from your source
   image.

   Run the following commands in your terminal:
   ```bash
   # Define Source and Destination
   SRC="Media/icon_original.png"
   DEST="Media/AppIcon.iconset"

   # Helper function
   gen_icon() { sips -s format png -z $1 $1 "$SRC" --out "$DEST/$2"; }

   # Generate standard and retina sizes
   gen_icon 16   "icon_16x16.png"
   gen_icon 32   "icon_16x16@2x.png"
   gen_icon 32   "icon_32x32.png"
   gen_icon 64   "icon_32x32@2x.png"
   gen_icon 128  "icon_128x128.png"
   gen_icon 256  "icon_128x128@2x.png"
   gen_icon 256  "icon_256x256.png"
   gen_icon 512  "icon_256x256@2x.png"
   gen_icon 512  "icon_512x512.png"
   gen_icon 1024 "icon_512x512@2x.png"
   ```

3. **Generate ICNS:** Convert the iconset folder into a single `.icns` file.
   ```bash
   iconutil -c icns Media/AppIcon.iconset -o Media/AppIcon.icns
   ```

4. **Cleanup:** You can delete the iconset folder after generating the `.icns`.
   ```bash
   rm -rf Media/AppIcon.iconset
   ```

5. **Rebuild:** Run `./build.sh` to include the new icon in the app bundle.
