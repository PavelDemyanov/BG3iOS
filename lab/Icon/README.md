# Иконка BG3iOS

`icon-source.webp` — иконка, которую нарисовал автор (рогатый череп иллитида, красные глаза, щупальца, клинки),
1920×1920, без прозрачности; логотипа Larian в ней нет. В приложение идёт непрозрачный PNG 1024×1024:

```sh
magick icon-source.webp -resize 1024x1024 -background black -alpha remove -alpha off -strip \
  PNG24:../Sources/MacportLab/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
