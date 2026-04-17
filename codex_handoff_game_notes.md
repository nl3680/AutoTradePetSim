# Handoff Codex — état actuel du jeu, du système de trade et des scripts

## 1) Contexte général

Ce mémo résume tout ce qu'on a compris jusqu’ici du projet Roblox et des scripts liés :
- au **système de trade**
- à la **save client**
- à l’**inventaire**
- à la récupération des **UID**
- aux **exports** de données inventaire / définitions
- à l’objectif actuel de l’utilisateur

Ce document est pensé pour être repris directement par **Codex**.

---

## 2) Objectif actuel de l’utilisateur

L’objectif immédiat est de construire une logique automatisée autour du **trade** dans **son propre jeu** :

1. détecter une **demande de trade entrante**
2. l’accepter automatiquement
3. ajouter au trade des items configurés
4. se mettre **ready**
5. confirmer quand l’autre joueur est prêt
6. éviter de re-trade plusieurs fois les mêmes joueurs
7. ne plus avoir à chercher les **UID** des items à la main
8. exporter / comprendre correctement :
   - les items du jeu
   - les items réellement possédés
   - la différence entre **définition** d’item et **instance d’inventaire**

---

## 3) Structure importante trouvée

### 3.1 Loader principal
Un loader initialise les modules client / serveur et charge notamment :
- `Library.Client.Save`
- les modules client dans `Library.Client`
- les modules de `ServerScriptService.Library` côté serveur

Le loader appelle côté client :
- `require(script:WaitForChild("Client"):WaitForChild("Save")).FetchPlayer(game:GetService("Players").LocalPlayer)`

Donc les stats / save du joueur local sont bien chargées côté client.

---

### 3.2 Module principal du trade
Le module principal trouvé pour les commandes de trade est :

`ReplicatedStorage.Library.Client.TradingCmds`

C’est ce module qui expose notamment :
- `Request(player)`
- `Reject(player)`
- `Decline()`
- `SetReady(bool)`
- `SetConfirmed(bool)`
- `SetItem(class, uid, amount)`
- `Message(text)`
- `SetCurrency(currencyName, amount)`
- `GetState()`
- `GetAllRequests()`
- `GetRequestFromPlayer(player)`
- `HasRequestFromPlayer(player)`
- `GetOutgoingRequestToPlayer(player)`
- `HasOutgoingRequestToPlayer(player)`

---

### 3.3 État de trade actif
Le module interne lié à l’état du trade est :

`ReplicatedStorage.Library.Client.TradingCmds.TradeState`

Ce module gère entre autres :
- `_id` → id du trade
- `_players`
- `_items`
- `_ready`
- `_confirmed`
- `_counter`
- `_lastModified`

Et il émet des events comme :
- `TradeCreated`
- `TradeSetReady`
- `TradeSetConfirmed`
- `TradeSetItem`
- `TradeMessage`
- `TradeExecuting`
- `TradeDestroyed`

---

### 3.4 Save client
Le module save client est :

`ReplicatedStorage.Library.Client.Save`

Il charge les données via :

- `r_Network.Invoke("Get Stats", player)`

Puis les stocke localement dans une table de saves.

Fonctions importantes :
- `Save.Get(player?)`
- `Save.FetchPlayer(player)`

La save locale contient notamment :

- `Save.Inventory`
- `Save.ItemIndex`
- `Save.TradeHistory`
- `Save.ZoneQuests`
- `Save.MailLog`
- etc.

---

### 3.5 Inventaire client
Le module principal d’accès inventaire est :

`ReplicatedStorage.Library.Client.InventoryCmds`

Points importants :
- `InventoryCmds.Container(player?)`
- le container vient d’un `ClientPlayerState`
- ce state est construit depuis la save chargée
- c’est ce container qui contient les **vrais objets item** côté client

Fonctions / accès observés :
- `Container()`
- `container:Store()`
- `container:All(typeObj)`
- `container:FindExact(itemPrototype)`
- `container:FindAny(...)`
- `container:Get(...)`
- `container:Each(...)` existe, mais son comportement exact n’a pas été totalement validé dans les tests faits

---

### 3.6 Currency
Le module currency client trouvé :

`ReplicatedStorage.Library.Client.CurrencyCmds`

Fonction utile :
- `GetItem(nameOrIndex)`

Chaîne de récupération :
1. `CurrencyCmds.GetItem("Diamonds")`
2. récupère le prototype currency correspondant
3. récupère le vrai item dans `InventoryCmds.Container()`
4. renvoie un **objet inventaire réel**
5. cet objet a un `GetUID()` et un `GetAmount()`

---

## 4) Compréhension du système de trade

### 4.1 Envoyer une demande de trade
Remote connu :

`ReplicatedStorage.Network["Server: Trading: Request"]`

Exemple observé :
- `InvokeServer(playerCible)`

Dans `TradingCmds.Request(player)` :
- le client appelle `r_Network.Invoke("Server: Trading: Request", player)`

---

### 4.2 Accepter une demande entrante
Dans ce système, accepter une demande entrante ne passe pas par un remote spécial “accept”.
La logique trouvée indique qu’**accepter revient à refaire une `Request(player)` vers le joueur qui t’a envoyé la demande**.

Donc côté client :
- si A a envoyé une demande à B
- B peut accepter en appelant `TradingCmds.Request(A)`

---

### 4.3 Comment les demandes “en attente” sont stockées
On a identifié une table locale :

- `t_u_1`

Elle sert à stocker les demandes.

Fonction trouvée :
- `requests(player)` retourne / crée `t_u_1[player]`

À réception d’un event réseau :
- `r_Network.Fired("Trading: Request")`

Le code fait :
- `requests(p49)[p50] = p51`

Interprétation :
- `t_u_1[fromPlayer][toPlayer] = data`

Il existe aussi :
- `GetAllRequests()`
- `GetRequestFromPlayer(player)`
- `HasRequestFromPlayer(player)`
- `GetOutgoingRequestToPlayer(player)`
- `HasOutgoingRequestToPlayer(player)`

---

### 4.4 Event réseau réel côté client
Le point important découvert :
le jeu n’utilise pas seulement un `RemoteEvent.OnClientEvent` visible “brut”, mais un wrapper réseau :

- `r_Network.Fired("Trading: Request")`
- `r_Network.Fired("Trading: Created")`
- `r_Network.Fired("Trading: Set Ready")`
- `r_Network.Fired("Trading: Set Confirmed")`
- `r_Network.Fired("Trading: Set Item")`
- `r_Network.Fired("Trading: Message")`
- `r_Network.Fired("Trading: Executing")`
- `r_Network.Fired("Trading: Destroyed")`

C’est pour ça que les tests initiaux basés seulement sur `OnClientEvent` ne montraient pas tout.

---

### 4.5 Création du trade actif
Quand un trade est créé, le code client reçoit :

- `r_Network.Fired("Trading: Created")`

Il supprime alors les demandes pending entre les deux joueurs,
puis crée un `TradeState` actif dans une table locale :
- `t_u_2[tradeId] = tradeState`

L’id actif courant est stocké dans :
- `v_u_3`

Et `TradingCmds.GetState()` retourne l’état du trade actif.

---

### 4.6 SetItem / Ready / Confirmed
Dans `TradingCmds` :
- `SetItem(class, uid, amount)` utilise `GetState()` puis appelle :
  - `r_Network.Invoke("Server: Trading: Set Item", state._id, class, uid, amount)`

- `SetReady(bool)` appelle :
  - `r_Network.Invoke("Server: Trading: Set Ready", state._id, bool, state._counter)`

- `SetConfirmed(bool)` appelle :
  - `r_Network.Invoke("Server: Trading: Set Confirmed", state._id, bool, state._counter)`

Conclusion importante :
- il ne faut pas hardcoder un tradeId genre `5` ou `12`
- il faut prendre **l’id du trade actif courant** via `TradingCmds.GetState()._id`

---

## 5) Compréhension des UID

### 5.1 Définition vs instance
Différence essentielle :

#### Définition globale d’un item
Dans `ReplicatedStorage.Library.Directory`, on trouve les **définitions** des items :
- nom interne
- display name
- classe
- index éventuel
- autres métadonnées

Exemple :
- `class=MiscItems | name=Comet | id=Comet | display=Comet`

Ça signifie juste :
- l’item **Comet existe dans le jeu**

Mais il n’a pas forcément d’UID ici.

#### Instance possédée par le joueur
Quand le joueur possède réellement un item :
- cet item a un **UID unique**
- cet UID existe dans l’inventaire du joueur / le container reconstruit
- c’est cet UID qui sert pour le trade

Conclusion :
- **Directory** → définitions globales
- **Inventory** → vraies instances du joueur avec UID

---

### 5.2 Où obtenir un UID
Dans `TradingCmds`, pour les currencies, le pattern trouvé est :

- `CurrencyCmds.GetItem(name)` → renvoie un objet inventaire
- puis le trade utilise :
  - `item.Class.Name`
  - `item:GetUID()`

Donc l’UID vient de l’objet inventaire réel,
pas du nom global de l’item.

---

### 5.3 Conséquence importante
Un item qui existe dans le jeu mais que le joueur **ne possède pas** :
- n’apparaît pas dans l’inventaire du joueur
- n’a donc **pas d’UID joueur disponible**
- ne peut pas être set dans le trade tant qu’il n’existe pas réellement dans l’inventaire

Exemple :
- définition globale `Comet` trouvée dans `Directory`
- mais tant que le joueur n’a pas un vrai `Comet` dans son inventaire, il n’y a pas de `uid=...` à fournir au trade

---

## 6) Travail déjà fait sur les scripts

### 6.1 Tentative d’automatisation du trade
Une logique d’auto-trade a été préparée conceptuellement :

- écouter `TradeRequested`
- accepter automatiquement si le joueur n’a pas déjà été traité
- attendre `TradeCreated`
- ajouter les items configurés
- faire `SetReady(true)`
- attendre que l’autre joueur soit ready
- faire `SetConfirmed(true)`
- marquer le joueur comme déjà traité

Cette logique reposait sur `TradingCmds`.

Remarque :
- une persistance durable sur Roblox normal demanderait un stockage serveur type DataStore
- côté environnement script local, une alternative proposée était une mémoire de session seulement, ou un fichier local si l’environnement le permet

---

### 6.2 Export brut des UID
Un premier script a été écrit pour scanner la save entière et repérer tout ce qui ressemblait à un UID hexadécimal 32 caractères.

Résultat :
- il récupérait trop de choses :
  - `ZoneQuests.*.UID`
  - `MailLog.*.UUID`
  - `TradeHistory.*`
  - etc.

Ce script a été jugé trop large.

---

### 6.3 Export inventaire corrigé
Une version corrigée a ensuite été proposée pour scanner uniquement :

- `Save.Inventory`

Objectif :
- sortir un fichier texte avec :
  - `class`
  - `name`
  - `uid`
  - `amount`
  - `path`

Le nom était récupéré en priorité via :
- `data.id`
- sinon `_id`, `name`, `Name`, etc.

Ça a permis de mieux distinguer les vrais items possédés.

---

### 6.4 Export des définitions globales
Un autre script a été écrit pour scanner tous les modules dans :

- `ReplicatedStorage.Library.Directory`

et produire un fichier type :
- `all_game_definitions.txt`

Ce fichier liste :
- classe / module
- nom interne
- display
- index éventuel
- métadonnées simples

Problème rencontré :
- certains modules comme `DropTables` utilisaient des métatables / `__index` custom
- un accès direct type `value.id` provoquait des erreurs du style :
  - `Unknown Droptable 'Balloons.id'`

Fix appliqué :
- utiliser `rawget(...)` / accès safe plutôt que `value.id` direct

---

### 6.5 Conclusion sur les deux fichiers
Deux fichiers ont été conceptualisés :

#### 1. `inventory_with_names.txt`
Contient :
- seulement les items réellement possédés
- avec UID joueur

#### 2. `all_game_definitions.txt`
Contient :
- tous les items / définitions globales du jeu
- sans UID joueur en général

Conclusion :
- les UID se trouvent surtout dans le premier
- les noms globaux / display / catalogues du jeu se trouvent dans le second

---

## 7) Découverte importante depuis les tests écran

Un screen a montré explicitement qu’un item currency résolu correctement ressemblait à ça :

```lua
item = {
  class = "Currency",
  data = {
    id = "Diamonds",
    _am = 797237
  },
  uid = "dbf308269b9e47298e53d91c76480926"
}
```

Cette structure confirme :
- `data.id` = nom interne de l’item
- `_am` = quantité
- `uid` = vrai identifiant d’instance pour le joueur

C’est exactement le format logique qu’il faut viser pour automatiser la mise au trade.

---

## 8) Réponse pratique à la question “comment trade 10 Comet ?”

Pour trade 10 Comet :
1. il faut posséder un vrai item Comet dans l’inventaire
2. il faut récupérer automatiquement :
   - `class`
   - `uid`
   - `amount`
3. il faut avoir un trade actif
4. il faut appeler :
   - `TradingCmds.SetItem(class, uid, 10)`

Dans la pratique, si l’item est stackable :
- un seul UID + quantité suffit

Sinon :
- il faut plusieurs UID

Le plus pratique n’est donc pas d’écrire l’UID à la main,
mais de faire une recherche par nom dans `Save.Inventory`.

---

## 9) Approche la plus pratique recommandée

### Fonction à construire
Le plus pratique est une fonction du style :

- `findOwnedItemByName("Comet")`
- `TradeItemByName("Comet", 10)`

Logique :
1. lire `Save.Get(LocalPlayer).Inventory`
2. parcourir les buckets :
   - `Currency`
   - `Misc`
   - `Pet`
   - etc.
3. pour chaque UID :
   - lire `data.id`
4. si `data.id == nomCherché` :
   - retourner `class`
   - `uid`
   - `amount`
5. appeler `TradingCmds.SetItem(class, uid, wantedAmount)`

Avantage :
- plus besoin d’aller chercher l’UID manuellement à chaque fois

---

## 10) Problèmes / limites observés

### 10.1 `container:All(...)`
Le retour de `container:All(itemType)` n’a pas été simple à parcourir dans les tests.
On a bien confirmé que :
- `container` existe
- `store:GetType("Pet")`, `store:GetType("Misc")`, `store:GetType("Currency")` existent
- `container:All(typeObj)` renvoie bien quelque chose

Mais les essais de boucle simple n’ont pas donné directement les items attendus.

Conclusion :
- pour l’instant, l’approche la plus robuste reste de lire `Save.Inventory`
- ou d’utiliser des helpers déjà existants comme `CurrencyCmds.GetItem(...)`

---

### 10.2 Tous les items du jeu vs items réellement possédés
Question résolue :
- le fichier de définition globale ne contient normalement pas d’UID
- seul l’inventaire du joueur contient les UID des items réellement possédés

---

### 10.3 `MiscItems` vs `Misc`
Dans les définitions globales, certaines classes peuvent apparaître comme :
- `MiscItems`

Mais côté inventaire / trade, le nom de classe utilisé peut être :
- `Misc`

Il faut donc parfois normaliser la classe entre :
- la définition globale
- la structure d’inventaire
- le remote / `TradingCmds.SetItem(...)`

---

## 11) Ce que Codex devrait faire ensuite

### Priorité 1
Écrire une fonction fiable :

- `findOwnedItemByName(itemName)`

qui retourne :
- `class`
- `uid`
- `amount`
- éventuellement `data`

et qui lit directement `Save.Inventory`.

---

### Priorité 2
Écrire :

- `TradeItemByName(itemName, wantedAmount)`

qui :
1. trouve l’item dans l’inventaire
2. vérifie que la quantité est suffisante
3. appelle `TradingCmds.SetItem(class, uid, wantedAmount)`

---

### Priorité 3
Brancher cette fonction dans la logique d’auto-trade :
- réception d’une demande
- acceptation
- ajout d’items par nom
- ready
- confirmed

---

### Priorité 4
Créer un système de persistance des joueurs déjà tradés.
Deux options selon l’environnement :
- mémoire session seulement
- fichier local si l’environnement l’autorise
- ou DataStore si logique serveur propre du jeu

---

### Priorité 5
Fusionner les définitions globales et l’inventaire local pour obtenir un export final propre :
- `class`
- `name`
- `display`
- `uid`
- `amount`

---

## 12) Résumé ultra court

- `TradingCmds` est le module principal du trade
- les demandes pending passent par `r_Network.Fired("Trading: Request")`
- accepter une demande = refaire `Request(player)`
- le trade actif a un vrai `state._id`
- `SetItem` doit utiliser :
  - la vraie classe
  - le vrai UID
  - la quantité
- les UID ne sont pas dans les définitions globales
- les UID sont dans l’inventaire du joueur
- `Directory` = catalogue du jeu
- `Save.Inventory` = instances possédées
- la meilleure suite = recherche automatique par nom, pas UID manuel

---

## 13) Liste pratique des chemins importants

- `ReplicatedStorage.Library.Client.TradingCmds`
- `ReplicatedStorage.Library.Client.TradingCmds.TradeState`
- `ReplicatedStorage.Library.Client.Save`
- `ReplicatedStorage.Library.Client.InventoryCmds`
- `ReplicatedStorage.Library.Client.CurrencyCmds`
- `ReplicatedStorage.Library.Directory`
- `ReplicatedStorage.Network`

---

## 14) Exemple de cible fonctionnelle finale

Ce qu’on veut au final côté usage :

```lua
AutoAcceptTradeIfNeeded()
TradeItemByName("Comet", 10)
TradeItemByName("Diamonds", 5000)
SetReadyIfPossible()
ConfirmWhenOtherReady()
RememberPlayerAlreadyTraded(targetPlayer)
```

C’est la direction logique la plus pratique à continuer dans Codex.
