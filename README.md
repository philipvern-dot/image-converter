# Image Converter

A Windows program that converts pictures to PNG, JPEG, WebP, AVIF, SVG, GIF, TIFF, BMP, Icon, JPEG XL, JPEG 2000, QOI, and TGA.

Double-click **Image Converter** in this folder. If that shortcut does nothing, open `app\launch.vbs` once. That starts the program and repairs the shortcut.

Add one picture, many pictures, or a whole folder. New files go in the `converted` folder next to the program until you choose another folder. That choice is saved for the next run.

## Tools

The program looks for ImageMagick in `tools\ImageMagick\`.

ImageMagick is not in this repository. Copy an ImageMagick folder into `tools\ImageMagick\`, or run the Windows setup program `image_converter.exe`, which installs this program and ImageMagick for the current user, adds a Start menu entry, and registers an uninstall entry.

ImageMagick is made by ImageMagick Studio LLC. Its license is `tools\ImageMagick\License.txt`.

## License

This program is released under the MIT License. See [LICENSE](LICENSE).

ImageMagick is a separate program and keeps its own license.
