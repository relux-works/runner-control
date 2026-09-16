# Runner removal (in scope for this release)

## Two operations (never confused)

1. **Убрать из приложения**: deletes only the catalog entry (directory
   record). Warns if the service keeps running. Deletes no files, no GitHub
   registration, no certificates. Implemented with the catalog slice
   (TASK-260916-304bw2).
2. **Удалить runner из GitHub**: separate future scenario using
   registration/remove tokens. Not the same button; requires explicit scope
   and confirmation.

## Rules

- Removing from the app never stops, unregisters, or deletes the working
  installation.
- A removed-then-readded directory reuses discovery validation
  (canonical path dedupe, no double import via symlink).
- UI copy must name which operation runs; destructive GitHub removal needs
  typed confirmation and shows the exact scope/registration ID.
