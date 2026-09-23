# My Homelab Container Stacks

- [Managers](managers)
  - [Arcane](https://getarcane.app/)
  - [Dockhand](https://dockhand.pro/)
  - [DBX](https://dbxio.com/en)
  - [PostgreSQL](https://www.postgresql.org/)
- [Traefik](stacks/traefik)

### Setup

1. Once you have cloned this repo, create a symlink to `/opt`

   ```sh
   ln -s <clone-dir>/managers /opt/managers
   ln -s <clone-dir>/stacks /opt/stacks
   ```
2. Create a user-defined `shared` network

   ```sh
   docker network create -d bridge --attachable shared
   ```
3. Configure `traefik` if you need HTTPS access, otherwise skip this step

   ```sh
   cd /opt/stacks/traefik
   cp .env.example .env
   ```
   Once you've updated the `.env` file with the necessary values, now time to start the traefik service
   ```sh
   docker compose up -d 
   ```

   > [!NOTE]
   > You might need to wait a moment until traefik successfully create wildcard TLS certificate
   > with your configured domain name.

   Check the log using `docker compose logs -f`, until you saw something like these
   ```log
   traefik  | {"level":"info","domains":"yourdomain.tld, *.yourdomain.tld","message":"Validations succeeded; requesting certificates."}
   traefik  | {"level":"info","domains":"yourdomain.tld, *.yourdomain.tld","message":"Server responded with a certificate."}
   ```
4. Configure and start the managers
   ```sh
   cd /opt/managers
   cp .env.example .env
   ```
   After you update the `.env` file with the necessary values, now time to start the managers
   ```sh
   docker compose up -d 
   ```
   Once all services are up and running, time to provision the managers for the first time

   - Arcane uses it's [default credential](https://getarcane.app/docs/get-started/installation#6-open-arcane), once you've logged in you'll be asked to create new password.
   - Dockhand [disables authentication](https://dockhand.pro/manual/#quick-start) by default, but you can have one if you want to.
   - DBX will directly ask you to set the access password at the time you first time you visit it.