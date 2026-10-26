# Sefirah Source Hub

Application web (HTML/JS pur, sans build, sans terminal) pour trouver, importer, convertir, créer et tester des sources Lua du plugin KOReader **Sefirah**.

## Mettre en ligne gratuitement (sans terminal)
1. Crée un compte GitHub, puis un dépôt public `sefirah-source-hub`.
2. « Add file › Upload files » : glisse tout le contenu de ce dossier (y compris `.github`) et valide.
3. Dépôt › Settings › Pages › Source : **GitHub Actions**. Le site sera sur `https://<ton-compte>.github.io/sefirah-source-hub/`.
   Limites GitHub Pages gratuit : dépôt public, ~1 Go de site, ~100 Go/mois de trafic (à vérifier sur la doc GitHub).
4. (Pour lire les sites) Cloudflare › Workers & Pages › Create Worker › colle `proxy/worker.js` › Deploy. Offre gratuite : ~100 000 requêtes/jour (à vérifier). Colle l'adresse dans l'onglet **Tester › Proxy**.

## Ce qui fonctionne réellement
- **Catalogue** : 22 sources Lua réelles de ton plugin (manifeste `sources/manifest.json`), recherche/filtres, voir le code, télécharger, copier le lien. Statut « non vérifié » partout : aucun test réel n'a encore été enregistré.
- **Importer** : dépôt/dossier/fichier GitHub public via l'API GitHub (60 requêtes/h sans jeton), langage, licence, doublons, import multiple.
- **Convertir** : Lua → vérification du contrat Sefirah, modules incompatibles, ligne `metas` ; JS/Kotlin/Dart → analyse partielle + pré-remplissage de « Créer ».
- **Créer** : détection de préfixes de liens et du formulaire de recherche, mode manuel, génération Lua (roman ou manga), sans IA.
- **Tester** : 10 contrôles réels (accueil, recherche, fiche, ordre des chapitres, lecture, images, accents, pages vides, blocage anti-bot).

## À configurer
- Proxy Cloudflare (sinon la plupart des sites échouent à cause de CORS).

## Reste à développer
- Conversion automatique de JS (LNReader) / Kotlin (Keiyoushi) : impossible en général, seule l'extraction d'infos existe.
- Filtres « Parcourir », auteur/genres/statut dans les sources générées.
- Catalogue communautaire par Pull Request : ajouter `sources/<id>.lua` + une entrée dans `manifest.json`.
- Analyse par IA optionnelle (non implémentée ; une clé devrait rester côté proxy, jamais dans le frontend).

## Licences
Les sources dérivées de Mythos (unitreign) restent sous **GPL-3.0** ; conserve les en-têtes.
