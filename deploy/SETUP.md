# Guide de setup par service (serveur avec PostgreSQL et ancienne version de collect-api)

Hypothèses : le serveur a déjà une instance PostgreSQL et une ancienne version de collect-api qui tourne. Les images sont sur Docker Hub (`adamlk/*`). Les noms d'hôte, ports et mots de passe ci-dessous sont à adapter.

## 0. Vue d'ensemble et ordre de déploiement

| Ordre | Composant | Nouveau ? | Port | Base |
|---|---|---|---|---|
| 1 | Sauvegarde + bases PostgreSQL | - | - | - |
| 2 | segmentation-service | oui | 8092 | `segmentation_service` |
| 3 | notification-service | oui | 8095 | `notification_service` |
| 4 | case-service | oui | 8091 | `case_service` |
| 5 | collect-api | **mise à jour** | 9090 | `debt_collect_db` (existante) |
| 6 | workflow-service | oui | 8094 | `workflow_service` |
| 7 | api-gateway | oui | 8090 | aucune |
| 8 | new-frontend | oui | 8080 (conteneur) | aucune |

Pourquoi cet ordre : workflow-service appelle collect-api, case-service et notification-service, et collect-api appelle segmentation-service et workflow-service. Les services appelés doivent exister avant.

Prérequis communs :
- Un réseau Docker partagé : `docker network create collect-net`.
- Deux secrets à générer : `SERVICE_TOKEN` (identique dans collect-api et workflow-service) et les mots de passe des bases.
- Chaque requête vers les services (hors `/actuator`, Swagger, API Flowable) doit porter l'en-tête `X-Tenant-Id` (valeur locale : `mercure`).
- Le point de santé de chaque service Java est `/actuator/health`.

## 1. PostgreSQL existant

### 1.1 Sauvegarde (obligatoire avant tout)

```bash
pg_dump -h <hote> -U <user> -Fc debt_collect_db > debt_collect_db_$(date +%F).dump
```

### 1.2 Bases et utilisateur des microservices

Les 4 microservices ont chacun leur base. Les migrations Flyway s'exécutent seules au démarrage ; les bases doivent être vides.

```sql
CREATE USER collector WITH PASSWORD '<mot-de-passe-micro>';
CREATE DATABASE case_service         OWNER collector;
CREATE DATABASE notification_service OWNER collector;
CREATE DATABASE workflow_service     OWNER collector;
CREATE DATABASE segmentation_service OWNER collector;
```

Si le serveur impose un autre nom d'utilisateur, utilisez-le dans `DB_USER`. L'utilisateur doit pouvoir créer des tables dans sa base.

La base `debt_collect_db` existe déjà : ne pas la recréer.

## 2. segmentation-service (8092)

Rôle : évalue les règles DMN, sans stocker de données métier.

```bash
docker run -d --name segmentation-service --network collect-net --restart unless-stopped \
  -e DB_URL=jdbc:postgresql://<hote-pg>:5432/segmentation_service \
  -e DB_USER=collector -e DB_PASSWORD=<mot-de-passe-micro> \
  adamlk/segmentation-service:latest
```

Vérification : `curl http://segmentation-service:8092/actuator/health` doit répondre `UP`.

## 3. notification-service (8095)

Rôle : envoie les e-mails ; les SMS et appels sont simulés et copiés par e-mail.

```bash
docker run -d --name notification-service --network collect-net --restart unless-stopped \
  -e DB_URL=jdbc:postgresql://<hote-pg>:5432/notification_service \
  -e DB_USER=collector -e DB_PASSWORD=<mot-de-passe-micro> \
  -e MAIL_HOST=<smtp> -e MAIL_PORT=<port-smtp> \
  -e MAIL_USERNAME=<user-smtp> -e MAIL_PASSWORD=<mdp-smtp> \
  adamlk/notification-service:latest
```

Remarque : le service est configuré sans authentification SMTP (`mail.smtp.auth: false`). Si le SMTP du serveur exige une authentification ou TLS, dites-le-moi : il faudra une modification de configuration.

## 4. case-service (8091)

L'image `adamlk/case-service` n'est pas encore publiée : attendez ma confirmation.

```bash
docker run -d --name case-service --network collect-net --restart unless-stopped \
  -e DB_URL=jdbc:postgresql://<hote-pg>:5432/case_service \
  -e DB_USER=collector -e DB_PASSWORD=<mot-de-passe-micro> \
  adamlk/case-service:latest
```

## 5. collect-api : mise à jour de l'ancienne version (9090)

C'est l'étape à risque : la base contient déjà des données.

1. Sauvegarde faite (étape 1.1). Notez le tag ou le digest de l'ancienne image, pour pouvoir revenir en arrière.
2. Relevez la configuration actuelle de l'ancien conteneur (`docker inspect collect-api`) : variables `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, secrets JWT, profil. **Reprenez les mêmes valeurs**, sinon les sessions et les données ne seront plus cohérentes.
3. Ajoutez les nouvelles variables d'intégration (absentes de l'ancienne version) :
   - `INTEGRATION_TENANT_ID` (ex. `mercure`)
   - `INTEGRATION_SERVICE_TOKEN` (le `SERVICE_TOKEN`)
   - `SEGMENTATION_SERVICE_URL=http://segmentation-service:8092`
   - `WORKFLOW_SERVICE_URL=http://workflow-service:8094`
4. Remplacez le conteneur :

```bash
docker stop collect-api && docker rename collect-api collect-api-old
docker run -d --name collect-api --network collect-net --restart unless-stopped \
  -e DB_URL=jdbc:postgresql://<hote-pg>:5432/debt_collect_db \
  -e DB_USERNAME=<user> -e DB_PASSWORD=<mdp> \
  -e INTEGRATION_TENANT_ID=mercure \
  -e INTEGRATION_SERVICE_TOKEN=<SERVICE_TOKEN> \
  -e SEGMENTATION_SERVICE_URL=http://segmentation-service:8092 \
  -e WORKFLOW_SERVICE_URL=http://workflow-service:8094 \
  -p 9090:9090 \
  adamlk/collect-api:latest
```

Points d'attention :
- Le schéma est géré par Hibernate en mode `ddl-auto: update` (schéma `core`) : au premier démarrage, la nouvelle version ajoute des tables et des colonnes à la base existante. Elle ne supprime rien, mais ce changement est irréversible sans la sauvegarde.
- `SQL_INIT_MODE` vaut `never` par défaut : ne le changez pas, sinon `data.sql` serait rejoué sur vos données.
- Ne mettez pas le profil `dev` (il pointe vers un serveur de développement par défaut).
- Retour arrière : arrêter le nouveau conteneur, `docker rename collect-api-old collect-api && docker start collect-api`. Si le schéma a déjà été modifié, restaurer le dump avant.

Vérification : `/actuator/health` à `UP`, puis une connexion avec un compte existant.

## 6. workflow-service (8094)

Rôle : exécute le processus BPMN de recouvrement ; seul service qui appelle les autres.

```bash
docker run -d --name workflow-service --network collect-net --restart unless-stopped \
  -e DB_URL=jdbc:postgresql://<hote-pg>:5432/workflow_service \
  -e DB_USER=collector -e DB_PASSWORD=<mot-de-passe-micro> \
  -e DEBT_COLLECTION_BASE_URL=http://collect-api:9090 \
  -e DEBT_COLLECTION_SERVICE_TOKEN=<SERVICE_TOKEN> \
  -e CASE_SERVICE_URL=http://case-service:8091 \
  -e NOTIFICATION_SERVICE_URL=http://notification-service:8095 \
  adamlk/workflow-service:latest
```

Le moteur Flowable crée ses propres tables dans `workflow_service` au premier démarrage. Les délais des timers sont à l'échelle de démonstration par défaut (`RECOVERY_DAY_DURATION`, 1 minute = 1 jour) : fixez les valeurs de production avant d'ouvrir le service aux utilisateurs (`RECOVERY_DAY_DURATION`, `RECOVERY_PAYMENT_DEADLINE_DAYS`, `RECOVERY_FORMAL_NOTICE_DAYS`, `RECOVERY_LEGAL_TEAM_EMAIL`).

Côté collect-api, l'horloge du protocole (`PROTOCOL_ENABLED`, `PROTOCOL_DAY_DURATION`) est désactivée par défaut.

## 7. api-gateway (8090)

Rôle : point d'entrée unique. `/api/v1/segmentation/**`, `/api/v1/workflows/**` et `/api/v1/notifications/**` vont à leur service, tout le reste de `/api/**` va à collect-api. Aucune authentification à ce niveau.

```bash
docker run -d --name api-gateway --network collect-net --restart unless-stopped \
  -e COLLECT_API_URL=http://collect-api:9090 \
  -e SEGMENTATION_SERVICE_URL=http://segmentation-service:8092 \
  -e WORKFLOW_SERVICE_URL=http://workflow-service:8094 \
  -e NOTIFICATION_SERVICE_URL=http://notification-service:8095 \
  adamlk/api-gateway:latest
```

Ne pas exposer les ports 8091, 8092, 8094 et 8095 à l'extérieur : ces services n'ont pas d'authentification utilisateur.

## 8. new-frontend (8080 dans le conteneur)

Le nginx de l'image redirige `/api/` vers `API_GATEWAY_URL`.

```bash
docker run -d --name new-frontend --network collect-net --restart unless-stopped \
  -e API_GATEWAY_URL=http://api-gateway:8090 \
  -p 80:8080 \
  adamlk/new-frontend:latest
```

Si le serveur a déjà un reverse proxy (nginx, Traefik), pointez-le vers `new-frontend:8080` et gérez le HTTPS à ce niveau.

Attention : l'image `new-frontend:local` a été construite sans que je sache si elle est en mode « données de démonstration » (mock) ou en mode API. Vérifiez à l'ouverture que l'écran de connexion appelle bien `/api/v1/...`; sinon, il faut reconstruire l'image avec la configuration `gateway`.

## 9. Vérification finale

```bash
for s in segmentation-service:8092 notification-service:8095 case-service:8091 \
         workflow-service:8094 collect-api:9090 api-gateway:8090; do
  echo -n "$s "; curl -s http://$s/actuator/health; echo
done
```

Puis : ouvrir le frontend, se connecter, lancer une segmentation sur un dossier (`POST /api/v1/cases/{ref}/segmentation`) et vérifier qu'un `processInstanceId` est enregistré.

## 10. Alternative : docker compose

Le fichier `docker-compose.yml` de ce dossier lance tout, mais il crée ses propres bases PostgreSQL. Avec un PostgreSQL existant, retirez les services `postgres-micro` et `postgres-collect` et leurs `depends_on`, puis renseignez les `DB_URL` vers l'instance existante.
