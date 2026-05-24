“Works on my machine” starts out as a punchline or retort; at scale, however, its no laughing matter.

Platform teams have usually had two ways to respond. They can impose a strict boundary around development using technologies like dev containers, VMs, or cloud workspaces. This gives them control, but at the cost of making them responsible for building, testing, securing, and supporting the environments engineers work inside. Or platform teams can leave setup to individual teams and developers. This preserves local autonomy, but it lets drift accumulate until it shows up in CI, staging, production, or incident response.

There is a third path: standardize what the project needs without taking over how every developer works.

That is the purpose of this playbook.


###

Platform teams do not need to standardize every developer’s editor, terminal, laptop, shell, or workflow.

In fact, they probably shouldn’t attempt to do this.

Instead, the scope of their responsibility is to standardize **the project runtime contract**.

Engineering organizations scale when teams develop local knowledge, local conventions, and local feedback loops. An ML research team, an MLOps team, a DevEx team, and an infrastructure team do not all need the same tools, the same workflows, or the same day-to-day operating model. Each team should be free to function as a semi-autonomous subsystem with its own responsibilities, habits, and constraints.

This autonomy is so useful as to be essential. It allows teams to organize and optimize for the requirements of their unique workstreams. For example, an ML research team needs to iterate quickly across model architectures, datasets, and both Python and native dependencies, while an infrastructure team may work primarily with Terraform, Kubernetes, Helm, cloud IAM, and other systems, plus the CLI tools that tie these together: **`terraform`**, **`kubectl`**, **`helm`**, **`aws`**, **`jq`**, **`curl`** and so on. 

It’s counter-productive to expect both teams to use the same dev setups. At the opposite extreme, it is counter-productive to permit **each engineer on the team** to define their own local dev setup. The **team as a unit** can and should define standard toolchains, development shells, and workflows. But to leave this to individual engineers is to create the conditions for works-on-my-machine failure at scale. 


###

Historically, platform teams have had two ways to deal with this. The **first** was to impose a strict boundary in local dev with containers, VMs, or cloud workspaces. This enables control, but it also makes platform teams responsible for building, patching, securing, and supporting the environments within which teams work. The **second** was to leave local setup to individual teams or developers. This promotes autonomy at the expense of accumulating drift that later shows up in CI, staging, or production.

A better model is when the platform team standardizes how each team defines and reproduces their project environments … without forcing every team to standardize on the same environment.

In this model, platform teams provide a standard **project runtime contract**: i.e., the set of packages, language runtimes, env vars, hooks, aliases, build recipes, and tools each project depends on. This contract functions as the declarative source of truth for the development environment. When the contract changes, the environment changes with it; when an engineer enters a project, they get the environment declared by the contract. Q.E.D.: the contract **is** the environment; the environment **is** the contract.

Flox’s declarative model makes this possible. Teams identify the tools and workflows that fit their domains and workstreams; once they make these choices, the project environment becomes shared infrastructure. The platform team authors reproducible dev environments for each team, expressing pinned package dependencies, environment variables, and service definitions in human-readable TOML.

Under the hood, Flox’s machinery resolves a compatible dependency graph and materializes all defined dependencies as hashed, immutable paths in a local store. The Flox environment consists of a declarative manifest (**`manifest.toml`**), a lockfile that pins dependencies (**`manifest.lock`**), and, optionally, a JSON file that references a remote FloxHub environment. Not only does every engineer on the team get exactly the same environment—anytime and anywhere; on macOS _or_ Linux, x86-64 _or_ ARM—but every CI runner, every review workflow, and every deployment job consumes the same declared contract.

If necessary, other teams can reproduce the same environment (with the same contract) at any time.


### The Runtime Contract

A runtime contract is the set of project assumptions that must be shared for the project to build, test, run, debug, and deploy.

It includes:

* Language runtimes
* Compilers and native build tools
* System libraries
* Package managers
* Cloud and platform CLIs
* Database clients
* Environment variables
* Setup hooks
* Services
* Aliases and functions
* Build and test commands
* Release and deployment tooling

If this contract lives in a README, a Slack thread, a wiki, a series of docs in a Git repo, or someone’s head, nobody owns it in a meaningful way. Container-based workflows create a minimally viable form of ownership by making the image digest the controlled object: teams can build it, scan it, sign it, publish it, pin it, and require downstream systems to consume it. But this is to own the runtime as an artifact, not as a declared, reviewable, enforceable contract. The “contract” as such is inferred from the Dockerfile, lockfiles, base-image state, package indexes, the digest-pinned result, and other mutable variables. 

Meaningful ownership requires that the contract be declared, versioned, reviewable, and **have an enforcement mechanism**. This aligns with the logic and rigor of CI/CD and the ethos of DevOps.

Put differently: In the container model, teams **infer** the runtime contract from the artifact and the ecosystem used to produce it. In this scheme, the digest-pinned OCI image becomes the unit of control and promotion. But Flox makes the contract itself explicit and **declarable**: its identity, contents, resolution, realization, and materialization become reproducibly regenerable. With a Flox manifest and lockfile, anyone anywhere can materialize exactly the same build or runtime environment at any time.


### The Inferred Build / Runtime Contract

In a container-based workflow, the runtime contract is the Dockerfile, the dependency lockfiles, the image digest, and the deployment manifests taken together. The Dockerfile is a procedural build script that itemizes what goes into a runtime; the OCI image materializes that itemization; the digest pins the result; and CI/CD enforces the contract by building, testing, publishing, and deploying only artifacts that satisfy it.

With the container model, however, there is no equivalent to the declarative rigor of the Nix/Flox model: the contract is always **inferred**. Thus platform teams cannot point to any one authoritative artifact and say: “I can use this to regenerate the environment the project requires.”  Yes, they _can_ point to the OCI image and say: “This image encapsulates the runtime environment the project requires.” So long as teams pull and run the digest-pinned OCI image, and so long as this image is viable, reproducibility holds.

But maintaining a “contract” of this kind imposes two distinct operational burdens on platform teams. The **first** is that they become responsible for keeping digest-pinned images available, compatible with current infrastructure, and up-to-date, rebuilding them as requirements or conditions change. The **second** has to do with their [carrying cost](https://en.wikipedia.org/wiki/Carrying_cost): every change to the runtime contract gets materialized as a new digest-pinned image, which must first be rebuilt, pushed to a registry, pulled, tested, and validated. Keeping the contract (i.e., the digest-pinned image) current means rebuilding that image, resolving and revalidating its dependencies, scanning and signing the built artifact, pushing it to a registry, pulling it into each target context, testing it there, updating any deployment references, and preserving the old digest as a viable rollback target. Every amendment to the runtime contract becomes a fresh exercise in artifact production, distribution, testing, and digest-pinning.

The bigger danger is that the golden image becomes a golden calf. Think about it: the digest can tell you exactly which is the golden image; however, it can’t tell you how to _recreate_ that golden image from scratch. And because teams can’t reliably regenerate the same runtime from a Dockerfile—or from some combination of Dockerfile, lockfiles, base-image tags, package indexes, install scripts, registry state, and build context—the image becomes “sacred” in that there’s no recipe authoritative enough to recreate it.


### The Declared Build / Runtime Contract

Flox reverses this model. Instead of treating an already-built image as the authoritative expression of the runtime contract, Flox makes the contract itself declarative and authoritative. The environment definition (**`manifest.toml`**) names the packages, tools, services, variables, hooks, and/or build logic the project requires. The lockfile (**`manifest.lock`**) pins the resolved dependency graph. Flox materializes that graph into immutable store paths at the point of use.

This gives platform teams what the image-based model does not: an authoritative artifact they can use to reproducibly regenerate the project environment at any time, in any place.

A Flox environment consists of three basic parts:

-  **`manifest.toml`**, which declares the environment
-  **`manifest.lock`**, which pins the resolved package graph
-  **`env.json`** a reference that defines the environment as local (unversioned) or remote (versioned as a generation on FloxHub).

To share these three files—typically less than 256KB of text—is to share the Flox environment.

The Flox manifest is the contract; the Flox lockfile pins this contract. Running **`flox activate`** realizes the Flox environment, which materializes this contract on a specific machine at a specific point in time. It doesn’t matter whether this happens today, tomorrow, next week, or next year, the materialized environment will be exactly the same on that specific machine and its OS/hardware.

This is the core difference between a digest-pinned OCI image and a declarative, graph-backed Flox environment: A digest-pinned image gives teams a way to retrieve the same **already-built** runtime environment; a Flox environment gives teams a way to use the declared contract to **regenerate** the runtime environment from scratch. This means platform teams no longer need treat the packaged runtime as the only trustworthy representation of the environment. Instead:

-  They can review the Flox environment as a human-readable document: i.e., a contract;
-  They can version it using either a version control system (like Git), FloxHub, or both;
-  They can update it by making simple, atomic edits;
-  They can publish it, either to a remote Git repo or to FloxHub;
-  They can reference it, pointing to either Git commits or FloxHub generations;
-  They can promote it by referencing it at each distinct delivery stage of the SDLC;
-  Optionally, they can layer or compose it with other Flox environments, creating rich stacks.

The takeaway: the build or runtime is no longer trapped inside the artifact; the artifact—the Flox environment—**declares** the contract. It’s the difference between a perfectly baked strawberry short cake and a reproducible recipe for baking a strawberry short cake perfectly every time.


## The Flox Environment Explained

The Flox manifest is expressed in human- and agent-readable TOML. It defines packages, env vars, and services, as well as provides sections for startup hooks, aliases and functions, and even built-in build recipes. The Flox manifest below defines a complete runtime environment for Redis:

```toml
[install]
redis.pkg-path = "redis"
redis.pkg-group = "redis"

[vars]
REDIS_HOST = "127.0.0.1"
REDIS_PORT = "16379"

[hook]
on-activate = '''
export REDIS_DATA="$FLOX_ENV_CACHE/redis"

if [ ! -d "$REDIS_DATA" ]; then
  mkdir -p "$REDIS_DATA"
fi
'''

[services]
redis.command = '''
  REDIS_DATA="$FLOX_ENV_CACHE/redis"
  mkdir -p "$REDIS_DATA"
  exec redis-server \
    --bind "$REDIS_HOST" \
    --port "$REDIS_PORT" \
    --dir "$REDIS_DATA" \
    --daemonize no
'''
```

The Flox lockfile (**manifest.lock**) is expressed in JSON. It is usually the largest file in terms of size in a Flox environment. The lockfile for this Redis environment is 143 lines:

```json
{
  "lockfile-version": 1,
  "manifest": {
    "schema-version": "1.10.0",
    "install": {
      "redis": {
        "pkg-path": "redis",
        "pkg-group": "redis"
      }
    },
    "vars": {
      "REDIS_HOST": "127.0.0.1",
      "REDIS_PORT": "16379"
    },
    "hook": {
      "on-activate": "export REDIS_DATA=\"$FLOX_ENV_CACHE/redis\"\n\nif [ ! -d \"$REDIS_DATA\" ]; then\n  mkdir -p \"$REDIS_DATA\"\nfi\n"
    },
    "options": {},
    "services": {
      "redis": {
        "command": "  REDIS_DATA=\"$FLOX_ENV_CACHE/redis\"\n  mkdir -p \"$REDIS_DATA\"\n  exec redis-server \\\n    --bind \"$REDIS_HOST\" \\\n    --port \"$REDIS_PORT\" \\\n    --dir \"$REDIS_DATA\" \\\n    --daemonize no\n"
      }
    }
  },
  "packages": [
    {
      "attr_path": "redis",
      "broken": false,
      "derivation": "/nix/store/vzqm58pz3wnibb36m8z42vrdzjm3a7bs-redis-8.2.3.drv",
      "description": "Open source, advanced key-value store",
      "install_id": "redis",
      "license": "AGPL-3.0-only",
      "locked_url": "https://github.com/flox/nixpkgs?rev=15f4ee454b1dce334612fa6843b3e05cf546efab",
      "name": "redis-8.2.3",
      "pname": "redis",
      "rev": "15f4ee454b1dce334612fa6843b3e05cf546efab",
      "rev_count": 990025,
      "rev_date": "2026-04-30T19:45:37Z",
      "scrape_date": "2026-05-03T08:11:55.028153Z",
      "stabilities": [
        "unstable"
      ],
      "unfree": false,
      "version": "8.2.3",
      "outputs_to_install": [
        "out"
      ],
      "outputs": {
        "out": "/nix/store/by3hbamnpgsf31qmqjn662hmywvb3yj9-redis-8.2.3"
      },
      "system": "aarch64-darwin",
      "group": "redis",
      "priority": 5
    },
    {
      "attr_path": "redis",
      "broken": false,
      "derivation": "/nix/store/00m20y82yggqcw9c6zqn2m3qaj5pwfm8-redis-8.2.3.drv",
      "description": "Open source, advanced key-value store",
      "install_id": "redis",
      "license": "AGPL-3.0-only",
      "locked_url": "https://github.com/flox/nixpkgs?rev=15f4ee454b1dce334612fa6843b3e05cf546efab",
      "name": "redis-8.2.3",
      "pname": "redis",
      "rev": "15f4ee454b1dce334612fa6843b3e05cf546efab",
      "rev_count": 990025,
      "rev_date": "2026-04-30T19:45:37Z",
      "scrape_date": "2026-05-03T08:46:31.811796Z",
      "stabilities": [
        "unstable"
      ],
      "unfree": false,
      "version": "8.2.3",
      "outputs_to_install": [
        "out"
      ],
      "outputs": {
        "out": "/nix/store/d01azmff4xa7rvkmcvg7p8cjwldj5bb8-redis-8.2.3"
      },
      "system": "aarch64-linux",
      "group": "redis",
      "priority": 5
    },
    {
      "attr_path": "redis",
      "broken": false,
      "derivation": "/nix/store/bicjrazdnpyczld0jwd4ryyhlz9r2fxm-redis-8.2.3.drv",
      "description": "Open source, advanced key-value store",
      "install_id": "redis",
      "license": "AGPL-3.0-only",
      "locked_url": "https://github.com/flox/nixpkgs?rev=15f4ee454b1dce334612fa6843b3e05cf546efab",
      "name": "redis-8.2.3",
      "pname": "redis",
      "rev": "15f4ee454b1dce334612fa6843b3e05cf546efab",
      "rev_count": 990025,
      "rev_date": "2026-04-30T19:45:37Z",
      "scrape_date": "2026-05-03T09:17:22.167984Z",
      "stabilities": [
        "unstable"
      ],
      "unfree": false,
      "version": "8.2.3",
      "outputs_to_install": [
        "out"
      ],
      "outputs": {
        "out": "/nix/store/6mdldz8k5k93zqw5y1n4jxi7zpwkr87h-redis-8.2.3"
      },
      "system": "x86_64-darwin",
      "group": "redis",
      "priority": 5
    },
    {
      "attr_path": "redis",
      "broken": false,
      "derivation": "/nix/store/nrb9f4bxs0r10b2a1g6zc7gnlr8ac8za-redis-8.2.3.drv",
      "description": "Open source, advanced key-value store",
      "install_id": "redis",
      "license": "AGPL-3.0-only",
      "locked_url": "https://github.com/flox/nixpkgs?rev=15f4ee454b1dce334612fa6843b3e05cf546efab",
      "name": "redis-8.2.3",
      "pname": "redis",
      "rev": "15f4ee454b1dce334612fa6843b3e05cf546efab",
      "rev_count": 990025,
      "rev_date": "2026-04-30T19:45:37Z",
      "scrape_date": "2026-05-03T09:54:14.568195Z",
      "stabilities": [
        "unstable"
      ],
      "unfree": false,
      "version": "8.2.3",
      "outputs_to_install": [
        "out"
      ],
      "outputs": {
        "out": "/nix/store/hccmzflw73ggnn61lvpvgz3yswsn5h0h-redis-8.2.3"
      },
      "system": "x86_64-linux",
      "group": "redis",
      "priority": 5
    }
  ]
}
```

The materialized Flox environment lives in **`$FLOX_ENV`**, corresponding to the path **`.flox/env/run`**. In this path, Flox materializes two distinct symlink forests:

-  A **developer-mode** environment that includes libraries or tools useful for development. Invoke at runtime with **`flox activate --mode dev`**, or define in the manifest: **`activate = { mode = 'dev' }`**. Developer mode is the default when activated locally; typically, you don’t need manually to set it.

-  A **runtime-mode** environment that restricts access to development libraries and tools. Invoke at runtime with **`flox activate --mode run`**, or define in the manifest: **`activate = { mode = 'run' }`**. In Flox’s [Imageless Kubernetes](https://flox.dev/docs/imageless-kubernetes/intro/) paradigm, **runtime mode** is the default. Some Kubernetes workloads may require **`flox activate --mode dev` to run.

So, for example, **`flox activate --mode dev`** materializes a development mode environment that symlinks to a unique immutable Nix store path:

```bash
$ ls -ahl $FLOX_ENV
lrwxrwxrwx 1 user user 63 May 13 11:45 /home/user/dev/redis/.flox/run/x86_64-linux.redis.dev -> /nix/store/mwvb4q700rhfds97lf57x6ijrys2bmfl-environment-develop
```

While activating **`flox activate --mode run`** materializes a runtime mode environment that symlinks to a unique immutable Nix store path:

```bash
$ ls -ahl $FLOX_ENV
lrwxrwxrwx 1 user user 63 May 13 11:45 /home/user/dev/redis/.flox/run/x86_64-linux.redis.run -> /nix/store/r6r562am71s50nwm70jdncqhaqwka30y-environment-runtime
```

The contents of these store paths consist of symlinks that point to packages in the immutable Nix store. The block below shows the contents of the Redis **development mode** store path:

```bash
$ ls -ahl /nix/store/mwvb4q700rhfds97lf57x6ijrys2bmfl-environment-develop
total 1.1M
dr-xr-xr-x    3 root root   4.0K Dec 31  1969 .
drwxrwxr-t 2817 root nixbld 992K May 13 12:25 ..
lrwxrwxrwx    1 root root     69 Dec 31  1969 activate -> /nix/store/h4ic554rlyb1k9qsmwncls6vr04qfsjh-flox-interpreter/activate
dr-xr-xr-x    2 root root   4.0K Dec 31  1969 activate.d
lrwxrwxrwx    1 root root     59 Dec 31  1969 bin -> /nix/store/hccmzflw73ggnn61lvpvgz3yswsn5h0h-redis-8.2.3/bin
lrwxrwxrwx    1 root root     64 Dec 31  1969 etc -> /nix/store/h4ic554rlyb1k9qsmwncls6vr04qfsjh-flox-interpreter/etc
lrwxrwxrwx    1 root root     75 Dec 31  1969 libexec -> /nix/store/qgbibh15gkchh9y4jg59hm25yjjr6svv-flox-activations-1.12.0/libexec
lrwxrwxrwx    1 root root     66 Dec 31  1969 manifest.lock -> /nix/store/91qm6m0ix3l7cb0qhaxi1jrwcyyhf2wi-manifest/manifest.lock
-r--r--r--    1 root root   6.5K Dec 31  1969 requisites.txt
lrwxrwxrwx    1 root root     72 Dec 31  1969 service-config.yaml -> /nix/store/91qm6m0ix3l7cb0qhaxi1jrwcyyhf2wi-manifest/service-config.yaml
```

Similarly, the block below shows those of the Redis **runtime mode** store path:

```bash
$ ls -ahl /nix/store/r6r562am71s50nwm70jdncqhaqwka30y-environment-runtime
total 1.1M
dr-xr-xr-x    3 root root   4.0K Dec 31  1969 .
drwxrwxr-t 2817 root nixbld 992K May 13 12:25 ..
lrwxrwxrwx    1 root root     69 Dec 31  1969 activate -> /nix/store/h4ic554rlyb1k9qsmwncls6vr04qfsjh-flox-interpreter/activate
dr-xr-xr-x    2 root root   4.0K Dec 31  1969 activate.d
lrwxrwxrwx    1 root root     59 Dec 31  1969 bin -> /nix/store/hccmzflw73ggnn61lvpvgz3yswsn5h0h-redis-8.2.3/bin
lrwxrwxrwx    1 root root     64 Dec 31  1969 etc -> /nix/store/h4ic554rlyb1k9qsmwncls6vr04qfsjh-flox-interpreter/etc
lrwxrwxrwx    1 root root     75 Dec 31  1969 libexec -> /nix/store/qgbibh15gkchh9y4jg59hm25yjjr6svv-flox-activations-1.12.0/libexec
lrwxrwxrwx    1 root root     66 Dec 31  1969 manifest.lock -> /nix/store/91qm6m0ix3l7cb0qhaxi1jrwcyyhf2wi-manifest/manifest.lock
-r--r--r--    1 root root   6.5K Dec 31  1969 requisites.txt
lrwxrwxrwx    1 root root     72 Dec 31  1969 service-config.yaml -> /nix/store/91qm6m0ix3l7cb0qhaxi1jrwcyyhf2wi-manifest/service-config.yaml
```

Each file and folder symlinks to an immutable Nix store path. These symlinks get created dynamically when Flox’s machinery first materializes the environment. They **are** the environment. During activation, Flox exports variables declared in **`[vars]`** and runs shell logic defined in **`[hook]`** and **`[profile]`**. It prepends the activated environment’s command paths to **`PATH`**, so shell lookup always resolves names such as **`redis-server`** against the Flox-pinned environment before searching host-specific **`PATH`** entries. Users can access tools, libraries, and services from within the activated Redis environment; outside of this environment, neither they nor environment variables, setup hooks, and services are accessible on the host.

This means engineers need not be cordoned inside a containerized userspace or VM in order to standardize a project’s runtime. It means platform teams can define the runtime contract declaratively, pin its dependency graph, and materialize exactly the same environment on each engineer’s host machine. It means dev teams retain autonomy over the tools and workflows that suit their domains and workstreams. It means platform teams own the operating model for the runtime contract, defining how environments get declared; how changes get reviewed; how shared foundations get published; how CI consumes them; how vulnerable hashes get blocked; and how teams promote or roll back environment versions. It means the organization as a whole standardizes at the ideal boundary: not a single least-common-denominator environment per team or engineer, but a single, standard, declared runtime contract per project or workstream.


## Playbook 1: Inventory the Runtime Contract

Don’t start with an ambitious platform-wide standardization effort. Pick a project that matters, changes often, and has been a source of recurrent pain: complicated local setup, slow onboarding, chronic “works on my machine” problems, CI failures, or repeated questions about which tools to install.

The goal of this first playbook is to discover the project’s runtime contract as it exists today. That contract is scattered across README steps, shell scripts, CI YAML, Dockerfiles, Compose files, package lockfiles, and deployment manifests. It is isolated in each engineer’s head, held together by habits.

The platform team’s goal is to turn this implicit contract into an explicit inventory.


### Start with the evidence

For the selected repo, inspect the artifacts that are supposed to describe how the project runs:

-  README / docs: What do developers install by hand?
-  CI config: What does automation install before tests run?
-  Dockerfile: Which packages, language runtimes, libraries, and setup steps get built into images?
-  Compose files: Which backing services does the project expect?
-  Package lockfiles: Which language-level dependencies does the project pin?
-  Shell scripts / Makefiles: Which commands do developers actually run?
-  Deployment manifests: Which environment variables, services, ports, and runtime assumptions reach staging or production?
-  Developer interviews: Which steps are undocumented? For example, which steps do experienced team members perform without thinking?

The last category matters. The most important runtime assumptions often live in muscle memory: “Oh, you need a newer **`make`**,” “that only works with **`libstdc++`**,” “you have to export this variable,” “the migration script assumes **`jq`** or **`wget`**,” or “that test only works if Redis is already running.”

These are not side notes. They are part of the contract.

### Sort the findings into categories

The inventory must distinguish between project runtime dependencies, backing services, and the personal preferences of each engineer’s workflow. A useful first pass might look like this:

```
Project: payments-api

Project runtime:
- Node.js 24
- Python 3.13
- gcc
- gnumake
- pkg-config
- PostgreSQL client libraries
- kubectl
- terraform

Backing services:
- PostgreSQL
- Redis

Environment variables:
- PGHOST
- PGPORT
- REDIS_URL
- APP_ENV

Setup behavior:
- create local cache directory
- install language-specific packages
- export database defaults
- run migrations before first launch

Commands:
- test
- lint
- migrate
- dev
- deploy-plan

Local-only preferences:
- editor
- shell theme
- terminal emulator
- personal Git aliases
```

This distinction—between what belongs to the project environment and what is the prerogative of the individual engineer—is fundamental. The contract should standardize the things every contributor, CI runner, review job, agent, or deployment workflow needs in order to interact and work with the project. (These include packages, runtimes, CLIs, services, variables, hooks, aliases, commands, and build logic.) Just as important, the contract should make explicit that which it **does not** standardize: editors, terminals, shells, local debugging preferences, and other personal aspects of each engineer’s workflow.



## Playbook 2: Decide Where the Service Boundary Belongs

Once the team inventories the runtime contract, the next question concerns how to implement and honor its terms. This playbook's first two sections are grounded on the assumption that human contributors, agents, and automated pipelines typically expect to run against the same services the org uses in production; in most cases, these services run as containers. **Section 1** covers how to distribute that responsibility among Flox, CI, and individual engineers. **Section 2** examines how to divide the runtime contract cleanly between Flox (the **project runtime**) and containers (**backing services**) to match real-world production conditions. **Section 3** covers when and why to use Flox-managed services.


###

This section looks at the build or runtime environment through three distinct lenses:

1. The shared tools required to run the code;
2. The automated guardrails that validate it;
3. The personal preferences of the engineers authoring it.

This section outlines a clear separation of concerns before pivoting to the question of backing services.


#### What Flox Is Responsible For

-  **Language runtimes and interpreters**. Node.js, Python, Go, Rust, Java, Ruby, and the like. 
-  **Compilers and build tools**. GCC and CLang; **`make`**, **`automake`**, **`cmake`**, etc.
-  **Database clients and database-specific dependencies**. Clients like **`psql`**, **`mysql`**, **`mariadb`**, **`redis-cli`**, and **`mongosh`**. Libraries like **`libpq`**, **`libmysqlclient`**, etc.
-  **CLI tools**, like **`git`**, **`gh`**, **`aws`**, **`kubectl`**, **`k9s`**, **`terraform`**, etc.
-  **Environment variables**. These define shared project defaults, such as database connection settings, mode (**`APP_ENV`**, **`NODE_ENV`**), logging (**`LOG_LEVEL`**), and feature flags.
-  **Setup hooks**. These idempotently bootstrap project setup, such as creating a Python virtual environment; preparing cache directories, exporting derived paths, etc.
-  **Aliases and shell functions**. These improve the environment’s UX or DX: e.g., shortcuts for accessing, migrating, or inspecting services; wrappers for CLI tools like **`gh`**, **`aws`**, or **`kubectl`**.
-  **Task entrypoint wrappers** for commands the team needs to run the same way every time: **`test`**, **`lint`**, **`format`**, **`build`**, **`migrate`**, **`seed`**, **`serve`**, and **`release`**. These usually wrap the underlying tools in Make targets, Just recipes, package-manager scripts, repo scripts, etc.
- **`Build recipes`**, if teams are building, packaging, and publishing with Flox.

<info box>
**Note**: Put literal values only under **`[vars]`**; values derived from the runtime context, such as repo-relative paths, cache directories, venv paths, and **`PATH`** edits, belong in **`[hook].on-activate`**.
</info box>


#### What CI Is Responsible For

- **Running the same Flox environment used by contributors**. CI always runs with the project’s declared runtimes, compilers, database clients, and CLIs. The contract is clear: run the same bits everywhere.
- **Starting service containers needed for checks**. These include PostgreSQL, Redis, Airflow, Temporal, Kafka, Elasticsearch, MinIO, RabbitMQ, and any other backing services.
- **Running the project’s task entrypoints**. Testing **`test`**, **`lint`**, **`format`**, **`build`**, **`migrate`**, **`seed`**, and **`release`** and validating that they behave as expected.
- **Handling CI-only orchestration**. Waiting for health checks, running migrations before integration tests, collecting logs, uploading test reports, caching dependency stores, running matrix jobs.
- **Managing CI-only credentials and publication steps**. Registry tokens, cloud deploy credentials, signing keys, artifact uploads, package and/or image publishing operations, tagging, deployment.


#### What Each Individual Engineer Is Responsible For

- **Their editor and IDE preferences**. VS Code, vim, JetBrains IDEs, extensions, themes, keybindings etc.
- **Their terminal and shell preferences**. Choice of terminal emulator, shell, prompt theme, history behavior, and completion style. Any personal functions or aliases that aren’t part of the project workflow.
- **Local credentials and IAM config**. SSH keys, Git signing keys, personal access tokens, one-off service credentials stay local or use the team’s secrets manager. **Note**: Teams can use Flox to define tooling and wrappers for secure access, but Flox manifests should never contain secret values.
- **Their own machine-specific settings**. This category includes where they put the repo on local disk; the layout of their **`$HOME`** directory; their local hardware and its specific requirements, etc.


### Container-Managed Services in Local Dev

Containers make sense in local development when teams need to run against exactly the same services used elsewhere in the SDLC. If CI, staging, or production consume a specific Postgres, Redis, or other backing service image, it makes sense for engineers to run that same image locally. This gives the team an explicit service boundary and ensures that local development mimics the workflow used downstream.

This is especially useful when:

-  The team needs to test against the same OCI image CI or production uses;
-  The service specifies a production-like configuration that needs to be accounted for locally;
-  The project already expects to reset the service’s state via Compose or the container runtime;
-  The team prefers a hard boundary between the project runtime and the service runtime;
-  The organization already versions and governs the service using OCI images.

In this pattern, **Flox provides the project runtime**. Platform teams define Ruby, Python, Node.js, Go, Rust, Java, compilers, native libraries, database clients, platform CLIs, linters, formatters, test tools, and other dependencies. They set shell environment variables, define useful functions and services, etc. The Flox **`manifest.toml`** and **`manifest.lock`** become the contract for the _project environment_.

**Containers run the backing services**. They package and run PostgreSQL, Redis, MariaDB, MinIO, OpenSearch, or other long-running services behind a clear boundary. The Dockerfile/Compose file and container runtime become the contract for the _service artifact_: image, tag or digest, ports, volumes, health checks, credentials, initialization scripts, and restart behavior. Developers don’t work _inside_ that service runtime; they connect to it via its public interface, using clients and variables supplied by Flox.

The interface between the two contracts is explicit. The Flox manifest defines the variables the project uses to discover backing services—**`PGHOST`**, **`PGPORT`**, **`REDIS_URL`**, **`DATABASE_URL`**, etc.—along with socket paths, client tools, and so on.

The service side of the contract consists of the OCI image reference plus the configuration used to run it: a Compose file, Kubernetes manifest, **`docker run`** wrapper, or equivalent script that defines ports, credentials, health checks, volumes, initialization and restart behavior, and so on. 

For example:

```
Flox:
-  Ruby
-  Bundler
-  PostgreSQL client libraries
-  gcc / make / pkg-config
-  Rails CLI
-  test and migration commands

Containers:
- PostgreSQL
- Redis
```

This pattern lets engineers work on their local machines, with their own editors, shells, Unix sockets, and debugging tools; backing services run behind an explicit lifecycle, networking, and state boundary.

But this is only one valid pattern.


### Flox-Managed Services in Local Dev

Flox environments provide built-in service management. Platform teams can define packages, variables, hooks, and long-running services as part of the declared Flox environment. Postgres, Redis, and other services (even Kafka or Spark) can be part of a project’s Flox-defined runtime contract, defined either in the project environment’s manifest or composed/layered as modular environments on-demand.

If the team does not need to reproduce a downstream container image, or if a requirement is more opportunistic—e.g., “This project needs a local relational database” or “This test suite needs Postgres”—then a Flox-managed service might be the better fit. In this model, the service becomes part of the declared Flox environment: either defined as an explicit **`[postgres.service]`**; **`[include]`**ed as a composed environment in the manifest itself; or activated on-demand using a pattern called [layering](https://flox.dev/docs/tutorials/layering-multiple-environments/?h=layering), as shown below:

```
flox activate -s -r flox/postgres
```

This gives engineers a versioned, managed Postgres environment without requiring that they install Postgres globally; create and maintain a Compose file; install a container runtime; or configure container networking and/or storage. This service uses the same declared model as the project runtime. Engineers continue to work with transparent access to all local affordances: their own shells, local credentials, Unix sockets, project-local directories, and database settings they can inspect or modify as needed.

<infobox>
The decision is not “services always go in containers” or “services always go in Flox.”
The decision is: what is the authoritative contract for this service in this workflow?
</infobox>


### Produce the runtime contract inventory

This deliverable could take the form of a markdown document or an issue attached to the repo. It should be specific enough that human or machine intelligence could turn it into a Flox manifest.

An example:

```
Project: payments-api
Owner: Payments team
Platform contact: DevEx / Platform

Runtime contract:

Languages:
- Node.js 24
- Python 3.13

System tools:
- gcc
- gnumake
- pkg-config
- jq
- curl

Project CLIs:
- kubectl
- terraform

Libraries / clients:
- PostgreSQL client libraries

Backing services:
- PostgreSQL via Compose
- Redis via Compose

Variables:
- APP_ENV=development
- PGHOST=localhost
- PGPORT=5432
- REDIS_URL=redis://localhost:6379

Activation behavior:
- create project cache directory
- export database defaults
- activate Python virtualenv
- install pinned Python requirements when needed

Commands to expose:
- dev
- test
- lint
- migrate
- deploy-plan

Out of scope:
- editor choice
- terminal choice
- shell prompt
- personal Git aliases
```

At the end of this step, the team should have a clear answer to four questions:

-  What does the project need?
-  Which parts belong in Flox?
-  Which parts belong behind service boundaries?
-  Which parts should remain individual developer choice?

This inventory becomes the input to the next playbook: writing the first Flox environment.


## Playbook 3: Map Docker and Compose artifacts to a declared Flox environment

Once the team has inventoried the runtime contract and decided where the service boundary belongs, the next phase is to decompose and translate the Docker or Compose workflow that currently encodes it.

This playbook turns that boundary decision into a migration path. It demonstrates how to map existing Dockerfiles, Compose files, devcontainer configs, image tags or digests, entrypoint scripts, or service wrappers as inputs to Flox environments: package declarations, variables, hooks, aliases, task wrappers, services, build steps (if applicable), and the supporting CLIs that make the project runtime reproducible.

The examples that follow show how to inspect those artifacts and map their relevant parts into `flox.toml`.

### 3. Start with the Evidence

Before authoring the Flox manifest, inspect the Docker-related artifacts already attached to the repo. Treat them as evidence for the current runtime contract. A useful inspection starts by asking what each artifact proves about the current development runtime and how that evidence maps to the Flox manifest:

**Dockerfile**. Map application-level build steps to the **`[install]`**, **`[vars]`**, and **`[hook]`** sections in the declarative Flox manifest. Probative examples include steps that package and install native libraries (executed via **`RUN`** commands); runtime environments specified via **`FROM`** image tags or **`ARG`** declarations; and environment variables set via **`ENV`** instructions.

Conversely, it typically makes sense to omit OCI-specific packaging instructions. Examples include **`COPY`** and **`WORKDIR`** instructions; layer cleanup optimizations; **`USER`** safety declarations; filesystem ownership operations like **`chown`**; and **`CMD/ENTRYPOINT`** paths.

**Docker Compose**. Map container runtime overrides to their equivalent runtime and/or wrapper definitions in the declarative Flox manifest. Common examples include execution targets that are declared via **`command`** directives; process variables that are injected via **`environment`** arrays; and host source paths that are mounted via **`bind`** volumes. Conversely, treat infrastructure dependencies as service boundaries that define which external resources the Flox environment must consume. Examples include host network mappings that are specified via **`ports`**; data states that are managed via named **`volumes`**; and orchestration-specific metadata like **`depends_on`** or health checks.

-  **Dev container configuration**. Map dev container configuration specs like **`devcontainer.json`** to dev-only dependencies, shell initialization steps, shell environment variables, and (optionally) helper functions or wrappers in the declarative Flox manifest. Common examples include language runtimes and global utilities declared via **`features`** objects; project-level package installation scripts that execute via **`postCreateCommand`** hooks; and logic that hydrates and sets up the shell environment. Conversely, editor-specific workspace preferences can typically be omitted unless coupled to strict toolchain dependencies. Examples include UI personalization settings and **`extensions`** arrays.

-  **Entrypoint scripts**. Map runtime initialization logic to hooks or explicit task wrappers in the declarative Flox manifest. Common examples include preflight checks; binary version or dependency existence checks; workspace state setup, like generating a cache directory; and running + like database migrations or seeding commands. Conversely, adapt or omit container-specific assumptions from the declared Flox environment. These include hardcoded absolute paths; initialization loop management for PID 1 processes; and (obviously) container bridge networking definitions.


CI configuration: Treat CI setup steps, test commands, lint commands, build commands, and service-container usage as evidence for the commands the Flox environment must make reproducible. When CI builds a Docker image only to obtain a test shell, treat that Docker build as strong evidence that the test shell should be declared directly in Flox.



## Playbook 4: Define and Commit the Environment with the Repo

Once the team has inventoried the runtime contract and decided where the service boundaries belong, the next move is to define the project environment and commit it with the repo.

This is the point at which the runtime contract becomes project infrastructure, with the Flox manifest defining the environment the project needs in order to run reproducibly; the lockfile pinning the resolved dependency graph; and the Git repo itself providing versioning, change management, and a review trail.

By the end of this playbook, the _repo_ itself should answer a basic question: “What does this project need to build, test, run, and deploy?” The answer should be legible as the declared Flox environment.


###

This section walks through an example project: a Python-backed web service with a Node-based frontend or asset pipeline; PostgreSQL-backed client and migrations tools; native build dependencies; and CLI deployment tooling. After discussion and iteration, the **`manifest.toml`** for this repo might look like:

```
[install]
## core runtime
node.pkg-path = "nodejs_24"
node.version = "24.14.1"

## python interpreter and supporting tools
python.pkg-path = "python3"
python.version = "3.13.12"
pip.pkg-path = "python313Packages.pip"
uv.pkg-path = "uv"

## python database tools
postgresql.pkg-path = "postgresql"
postgresql.version = "16.4"
# note: we keep postgres/libpq in its own resolver and upgrade group b/c
# pg_config, libpq, headers, and related native deps are consumed by
# python packages such as psycopg2, so we do not want unrelated cli/runtime
# upgrades to perturb this part of the dependency graph
postgresql.pkg-group = "postgresql"
alembic.pkg-path = "python313Packages.alembic"
alembic.version = "1.18.1"
sqlalchemy.pkg-path = "python313Packages.sqlalchemy"
sqlalchemy.version = "2.0.49"
gcc-unwrapped.pkg-path = "gcc-unwrapped" #  required for building and compiling python’s psycopg2

## native build tools
gnumake.pkg-path = "gnumake"
pkg-config.pkg-path = "pkg-config"

## cli infra tools
kubectl.pkg-path = "kubectl"
kubectl.version = "1.36.0"
terraform.pkg-path = "terraform"
terraform.version = "1.15.2"

[vars]
APP_ENV = "development"
PGHOST = "localhost"
PGPORT = "5432"


[hook]
on-activate = '''
set -e

export VIRTUAL_ENV="$FLOX_ENV_CACHE/venv"
export UV_CACHE_DIR="$FLOX_ENV_CACHE/uv"

mkdir -p "$UV_CACHE_DIR"

if [ ! -d "$VIRTUAL_ENV" ]; then
  uv venv "$VIRTUAL_ENV" --python python3
fi

export PATH="$VIRTUAL_ENV/bin:$PATH"

if [ -f "$FLOX_ENV_PROJECT/uv.lock" ] || [ -f "$FLOX_ENV_PROJECT/pyproject.toml" ]; then
  uv sync --project "$FLOX_ENV_PROJECT"
elif [ -f "$FLOX_ENV_PROJECT/requirements.txt" ]; then
  uv pip install --python "$VIRTUAL_ENV/bin/python" -r "$FLOX_ENV_PROJECT/requirements.txt"
fi
'''
```

This example does a good bit of runtime-contract work.

**1.** It tells contributors, CI jobs, code-generating tools, agents, and other consumers that this project requires specific, pinned versions of Node.js. Python 3.13, PostgreSQL, and CLI tools.

<info box>
**Note**: This example manifest defines and pins two Python 3.13 packages: SQLAlchemy and Alembic. The decision as to whether to use Python packages from the Flox Catalog _or_ get them at runtime via **`uv`**, **`pip`**, or other package manager is a nuanced one. This playbook explores the pluses and minuses of doing so in the **Flox, Nix, and Python Packages** section, below.
<info box>

**2.** It declares the package managers and build inputs required to assemble the Python side of the project environment: **`pip`**, **`uv`**, **`gcc-unwrapped`**, **`gnumake`**, and **`pkg-config`**.

**3.** The `postgresql` package contributes more than the **`psql`** CLI. It also provides **`pg_config`**, **`libpq`**, and the development headers that Python packages need when they build against Postgres.

We place `postgresql` into its own **[package group](https://flox.dev/docs/concepts/package-groups/?h=package)** because PostgreSQL 16.4 is older than the other runtimes and tools defined in this environment. Flox resolves every package in a package group against a single Flox Catalog revision. (A Flox Catalog revision is a point-in-time snapshot of upstream [nixpkgs](https://github.com/NixOS/nixpkgs).) PostgreSQL 16.4 resolves against an older, historical revision, circa August of 2024; the pinned versions of tools like **`kubectl`** and **`terraform`** resolve against a much newer one. No one revision will satisfy both. Isolating **`postgresql`** lets Flox resolve it independently while the rest of the environment resolves against a current revision. In this way, it’s possible for legacy and modern versions of tools and libraries to coexist in the same Flox environment.

**Note**: The values in **`[vars]`** set the project’s database-specific variables—**`PGHOST=localhost`** and **`PGPORT=5432`**—even though the environment itself doesn’t define a database service. These variables help the Postgres client and Python libraries discover and connect to the PostgreSQL container.

**4.** The activation **`[hook]`** creates a Python venv in **`$FLOX_ENV_CACHE`**, points **`uv`** at a cache inside the Flox environment, prepends the venv’s bin directory to **`PATH`**, and installs project Python dependencies with **`uv`**. If the project contains **`uv.lock`** or **`pyproject.toml`**, activation uses **`uv sync`**; otherwise, it falls back to **`requirements.txt`** via **`uv pip install`**.

For Flox environments that live and travel with project code, it’s essential to commit the files in the **`.flox/env/`** path: **`manifest.toml`** and **`manifest.lock`**. These files, along with **`env.json`** (which defines the environment as either unmanaged or FloxHub-managed), comprise the whole of the environment definition. To commit these files is to commit the environment in _toto_.

```
.flox/
├── env.json                 # managed/unmanaged environment metadata
└── env/
    ├── manifest.toml        # environment manifest
    └── manifest.lock        # locked environment resolution

Commit:	.flox/env/manifest.toml,
 		.flox/env/manifest.lock,
 		.flox/env.json
```

In most cases, the environment cache (**`.flox/cache`**); the materialized environment (**`.flox/run/`**, Flox log files (**`.flox/logs/`**); Python virtual environments; and Flox build outputs (denoted by **`result-<package-name>`** in the project directory) should not be committed; add them to **`.gitignore`**.

<info box>
Common-sense best practices apply: For example, never define and export secrets in the Flox manifest! 
<info box>

In the Flox model, changes to a project’s runtime environment and dependencies are always visible, attributable, reviewable, and reversible. The environment’s declarative definition gives dev and platform teams a shared object to inspect and discuss, so terms like “the runtime,” “the dependency set,” or “the promoted environment” mean the same thing and point to the same concrete files, lock, and reference.

This makes it practicable for teams to discuss, test, review the impact of, and promote changes—especially agent-authored changes. Promotion or rollback become an atomic edit to the reference (a specific Git commit, a FloxHub generation, even a Nix store path hash) used to run the environment.

Once committed, a project’s runtime becomes part of its normal development workflow. A change to a dependency change is no longer an undocumented/out-of-date instruction in a README, or a one-off command someone ran locally. It becomes a diff. Moreover, that diff can be reviewed:

```
-[install]
-## native build tools
+[install]
+## other tools
 gnumake.pkg-path = "gnumake"
 pkg-config.pkg-path = "pkg-config"
+jq.pkg-path = "jq"
```


