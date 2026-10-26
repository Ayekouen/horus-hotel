# Horus Hotel

SaaS de gestion d'hôtels et de résidences meublées (Côte d'Ivoire) : réservations, planning, clients, caisse, factures, abonnements, et pages publiques de réservation.

## Architecture
- **Frontend** : `index.html`, application statique en un seul fichier (aucun build). Bibliothèque `@supabase/supabase-js@2.45.4` chargée depuis jsDelivr.
- **Backend** : Supabase (projet `gestion-hoteliere`) — Postgres, RLS, fonctions `SECURITY DEFINER` contrôlant les droits côté serveur, Storage (`public-media`).
- **Hébergement actuel** : GitHub Pages (`guyayekkweeli-glitch/horus-hotel`, branche `main`) — https://guyayekkweeli-glitch.github.io/horus-hotel/. Vercel prévu ultérieurement.

## Pages publiques de réservation
- Adresse d'une page : `<adresse de l'application>?h=<identifiant>` (sans nom de domaine pour l'instant).
- Espace propriétaire : menu **Ma page publique** (identifiant, textes, photos, publication, confirmation automatique).
- API publique (rôle `anon`) : `public_get_establishment`, `public_quote`, `public_create_booking`. Prix et disponibilité calculés côté serveur, verrou transactionnel par établissement, contrainte d'exclusion anti-double réservation, limite de 3 demandes / téléphone / 24 h.
- Les demandes arrivent avec le statut `pending` (« En attente ») dans Réservations et Planning ; la chambre reste bloquée jusqu'à confirmation ou annulation.
- Une page n'est visible que si : publiée, établissement actif, abonnement valide (essai, actif, échéance dépassée ou résilié avant fin de période).

## Base de données
- `supabase/migrations/` : migrations versionnées (la migration 10 est la première exportée ; les migrations 01–09 sont appliquées sur le projet et listées dans `supabase_migrations.schema_migrations`).
- `supabase/tests/public_booking_test.sql` : 17 tests, exécutables dans le SQL Editor ; toutes les données de test sont annulées.
- `supabase/maintenance/nettoyage_donnees_de_test.sql` : suppression des organisations de test.

## Reste à faire
Sous-domaines et domaines personnalisés (nécessitent un nom de domaine), migration vers Vercel, paiement en ligne, notifications WhatsApp/SMS, contrôles anti-fraude du gérant.
