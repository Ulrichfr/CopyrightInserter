# Copyright Inserter

Application Mac, native Apple Silicon, pour poser une marque sur un dossier de photos. Les originaux ne sont pas modifiés.

Une image ou une ligne de texte, neuf positions ou un placement libre, opacité, ombre, marge. La largeur ou la hauteur peut être fixée : l’autre côté suit le ratio, et le logo est posé ensuite. L’aperçu montre le résultat. Par défaut, les coordonnées GPS sont retirées des copies.

Sans dossier de destination, les fichiers sont enregistrés à côté des originaux avec le préfixe `c_`.

## Construire

```bash
./build.sh
```

Le script teste le compositeur, signe `dist/Copyright Inserter.app` et écrit une image disque dans le dossier parent.

Xcode ou les outils de ligne de commande Apple suffisent. macOS 14 ou plus récent.
