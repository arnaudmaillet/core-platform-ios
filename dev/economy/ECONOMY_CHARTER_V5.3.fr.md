# Charte économique A/B — V5.3

## 1. Vision générale

Le système économique de SocialMap repose sur deux monnaies volontairement séparées :

- **A — capacité de curation** : permet à l'utilisateur d'engager une partie de sa capacité de curation sur un contenu.
- **B — récompense earned-only** : récompense a posteriori la valeur informationnelle démontrée par un créateur ou un curateur.

L'objectif n'est pas de transformer l'engagement social en marché de visibilité.

Le système doit plutôt transformer une partie de l'attention des utilisateurs en **signaux de curation économiquement engageants**, puis rémunérer uniquement les comportements dont la valeur est démontrée par une expérimentation contrôlée.

Le principe fondamental est :

> **A exprime une conviction avant le résultat. B récompense une valeur démontrée après le résultat.**

---

# 2. Pourquoi remplacer le Like par la mise A ?

Dans un réseau social ultra-fast, chaque post doit pouvoir être consommé rapidement.

Une interface présentant simultanément :

- Like
- réaction
- mise
- partage
- sauvegarde
- commentaire
- autres actions

risque d'introduire trop de choix et de ralentir la consommation.

La décision V5.3 est donc de **ne pas conserver le Like comme interaction principale**.

La mise devient l'action centrale du contenu.

### Modèle UX

```text
Consommer le contenu
        │
        ▼
     [ Miser ]
        │
        ├── mise rapide
        │
        └── options avancées
              ├── conviction
              └── montant
```

L'utilisateur n'a donc pas besoin de comprendre toute l'économie pour utiliser le produit.

Le geste principal devient simplement :

> **« Ce contenu mérite que la plateforme lui accorde davantage d'attention expérimentale. »**

---

# 3. La mise ne signifie pas simplement « j'aime »

La suppression du Like implique une distinction importante.

Le système ne mesure plus explicitement une préférence légère du type :

> « J'aime ce contenu. »

La mise mesure quelque chose de plus fort :

> « Je pense que ce contenu mérite d'être davantage testé / découvert par la plateforme. »

Cette différence est volontaire.

La mise A est donc un **signal de recommandation engageant**, pas une simple réaction émotionnelle.

Cela donne au produit une grammaire extrêmement simple :

| Action | Signification |
|---|---|
| Aucun geste | Je consomme |
| **Mise A** | Je pense que ce contenu mérite davantage d'expérimentation |
| Commentaire | J'apporte quelque chose à la discussion |
| Partage | Je recommande directement ce contenu à quelqu'un |
| Sauvegarde, si conservée | Je souhaite pouvoir le retrouver |

La mise n'a pas besoin de remplacer toutes les autres actions sociales.

Elle remplace principalement **le Like comme bouton de soutien principal**.

---

# 4. A — Capacité de curation

## 4.1 Nature

A est une capacité de curation distribuée aux utilisateurs.

A est :

- non achetable ;
- non transférable ;
- non convertible en B ;
- sans expiration ;
- plafonnée ;
- distribuée via des mécanismes de claims ;
- dépensée lorsqu'une curation est engagée.

Exemple de plafond :

```text
A_max = 2 000 A
```

Le montant exact reste un paramètre de calibration.

---

# 5. Pourquoi A n'est pas une monnaie classique

A ne doit pas être perçue comme de l'argent interne.

Un utilisateur ne doit pas pouvoir raisonner :

> « J'ai beaucoup d'A, donc je peux acheter de la visibilité. »

Au contraire :

> « J'ai une capacité limitée à exprimer mes convictions de curation. »

La différence est fondamentale.

**A n'achète jamais directement de visibilité.**

Une mise déclenche seulement une possibilité d'expérimentation.

---

# 6. Deux dimensions indépendantes : conviction et mise

Une curation comporte deux dimensions.

### Conviction

Niveau discret :

```text
C1
C2
C3
C4
```

Chaque niveau correspond à une probabilité implicite `p_i`.

Exemple initial :

```text
C1 = 0,25
C2 = 0,40
C3 = 0,60
C4 = 0,80
```

Ces valeurs sont des paramètres à calibrer et non des vérités économiques fixes.

### Mise

Le montant A représente la quantité de capacité que l'utilisateur accepte d'engager.

La mise ne doit pas directement déterminer la probabilité.

Ainsi :

```text
Conviction → probabilité implicite
Mise A     → quantité de capacité engagée
```

et non :

```text
Mise A → probabilité
```

Cela empêche un utilisateur riche en A de transformer mécaniquement son influence en certitude.

---

# 7. UX de la mise

Pour préserver le caractère ultra-fast du produit, l'utilisateur ne devrait pas obligatoirement parcourir quatre niveaux de conviction et plusieurs montants à chaque post.

L'interface peut privilégier :

### Mise rapide

```text
[Miser]
```

avec une valeur par défaut.

### Mise avancée

Accessible secondairement :

```text
Montant : 20 A
Conviction : C3
```

Cela permet de conserver une interaction extrêmement rapide tout en laissant aux utilisateurs avancés la possibilité d'exprimer une conviction précise.

---

# 8. Pipeline de curation d'un post

```text
POST
  │
  ▼
Prédiction figée à t0
  │
  ├───────────────┐
  ▼               ▼
Cohorte témoin   Cohorte test
  │               │
  │          Mises A
  │               │
  └───────┬───────┘
          ▼
Expérimentation contrôlée
          │
          ▼
Résultat indépendant Z_P
          │
          ├───────────────┐
          ▼               ▼
     ContentScore    CurationScore
          │               │
          ▼               ▼
  Pool B créateur   Pool B curateur
```

Le point essentiel est que la mise ne crée pas elle-même son propre résultat.

---

# 9. Cohorte témoin

La cohorte témoin doit rester indépendante des signaux A.

La prédiction du curateur est figée au moment de la curation :

```text
π_before_i
```

Le système attribue ensuite un résultat indépendant :

```text
Z_P
```

Par exemple :

> le contenu appartient-il finalement aux 15 % supérieurs selon le ContentScore dans une cohorte témoin ?

Le système ne doit pas simplement mesurer :

> « Le post a reçu beaucoup de vues après avoir reçu beaucoup de mises. »

Cela créerait une boucle circulaire.

---

# 10. Mesure de la qualité de la prédiction

En V1, une approche Brier Score peut être utilisée.

```text
PredictionValue
= Brier(π_before_i, Z_P)
  - Brier(baseline, Z_P)
```

ou, selon la convention retenue :

```text
PredictionValue
= Brier(π_before_i, Z_P)
  - Brier(reference, Z_P)
```

Puis :

```text
PredictionScore
= max(0, PredictionValue)
```

L'objectif est de mesurer si le curateur a apporté une information prédictive utile par rapport à une référence.

---

# 11. CurationScore

Le score du curateur ne doit pas être une simple fonction de popularité.

Modèle :

```text
RawInformationScore
=
PredictionScore
× MarginalContribution
× TemporalUtility
× EvidenceConfidence
× StakeFactor
```

Puis :

```text
SafetyAdjustment
=
Trust
× AntiFraud
× Relationship
```

Enfin :

```text
CurationScore
=
RawInformationScore
× SafetyAdjustment
```

---

# 12. PredictionScore

Mesure la qualité de la prédiction du curateur.

Un utilisateur qui mise correctement sur un contenu avant que sa qualité soit connue peut générer un signal utile.

Un utilisateur qui mise systématiquement sur les contenus déjà manifestement populaires ne doit pas obtenir la même valeur.

---

# 13. MarginalContribution

Le système doit chercher à mesurer la **valeur supplémentaire du curateur**.

Il ne suffit pas que plusieurs personnes aient fait la même prédiction.

Un signal doit apporter de l'information.

Une approximation initiale peut combiner :

```text
Réduction d'incertitude
× indépendance
× couverture
```

Une évolution ultérieure pourrait utiliser :

- leave-one-out ;
- Shapley value ;
- méthodes d'attribution marginale.

L'objectif reste le même :

> récompenser la contribution informationnelle, pas le nombre de personnes ayant fait la même chose.

---

# 14. TemporalUtility

La précocité peut avoir de la valeur.

Identifier tôt un contenu intéressant peut être plus utile qu'identifier le même contenu après qu'il soit déjà évident.

Mais la temporalité doit être bornée.

Il ne faut pas transformer la curation en :

> « Premier arrivé = meilleur curateur. »

La précocité est donc un facteur parmi d'autres.

---

# 15. EvidenceConfidence

Un résultat observé avec très peu de données ne doit pas avoir le même poids qu'un résultat statistiquement robuste.

Le système doit donc tenir compte de la confiance dans l'évaluation.

Cela limite les récompenses excessives provoquées par des événements aléatoires.

---

# 16. SafetyAdjustment

Le score doit également intégrer des protections :

```text
Trust
× AntiFraud
× Relationship
```

### Trust

Historique du comportement du curateur.

### AntiFraud

Détection de :

- Sybil ;
- multi-comptes ;
- bots ;
- collusion ;
- manipulation coordonnée.

### Relationship

Réduction éventuelle de la valeur d'un signal lorsqu'il existe une relation susceptible de biaiser fortement la curation.

---

# 17. Commentaires : même système, nouveau contexte

La même logique peut être appliquée aux commentaires.

Un commentaire devient lui aussi un objet curatable.

L'utilisateur peut donc :

```text
Post
 └── Miser

Commentaire
 └── Miser
```

Cela donne une grammaire extrêmement cohérente à l'application :

> **Miser = signaler qu'un élément mérite davantage d'attention.**

---

# 18. Que signifie miser sur un commentaire ?

La signification doit cependant être différente du post.

### Mise sur un post

> « Ce contenu mérite davantage d'expérimentation et de découverte. »

### Mise sur un commentaire

> « Cette contribution apporte une valeur particulière à la discussion. »

Le commentaire est donc évalué dans le contexte de la conversation.

---

# 19. Le commentaire ne doit pas automatiquement booster le post

Il faut séparer les deux objets.

```text
Post
 └── ContentScore(post)

Commentaire
 └── ContentScore(commentaire)
```

Une mise sur un commentaire doit principalement agir sur la visibilité et l'évaluation du commentaire.

Elle ne doit pas automatiquement augmenter le score du post parent.

Sinon un commentaire viral pourrait artificiellement faire monter un contenu original qui n'a pas lui-même démontré sa qualité.

---

# 20. ContentScore du commentaire

Le commentaire doit avoir son propre `ContentScore`.

Il peut notamment mesurer :

- apport informationnel ;
- pertinence ;
- qualité de la discussion ;
- contribution marginale ;
- fiabilité ;
- diversité d'information ;
- qualité des échanges générés ;
- absence de manipulation.

Le simple nombre de réponses ou de réactions n'est pas suffisant.

---

# 21. Récompense B de l'auteur du commentaire

Le système peut traiter un commentaire comme un contenu créatif à part entière.

Ainsi :

```text
Commentaire
      │
      ▼
ContentScore
      │
      ▼
Pool B créateur
      │
      ▼
Auteur du commentaire
```

Un auteur de commentaire peut donc recevoir du B si sa contribution démontre une valeur informationnelle suffisante.

---

# 22. Récompense B du curateur du commentaire

C'est également possible.

La curation d'un commentaire est évaluée séparément :

```text
Commentaire
      │
      ├───────────────┐
      ▼               ▼
ContentScore     CurationScore
      │               │
      ▼               ▼
Auteur            Curateur
      │               │
      ▼               ▼
Pool créateur     Pool curateur
      │               │
      └───────┬───────┘
              ▼
              B
```

Ainsi :

- **l'auteur du commentaire** est récompensé pour la valeur de sa contribution ;
- **le curateur** est récompensé pour avoir correctement identifié cette valeur.

Les deux comportements sont donc distincts.

---

# 23. Pourquoi récompenser les deux ?

Cela crée une boucle intéressante :

```text
Créateur :
produit de la valeur

Curateur :
identifie la valeur

Système :
mesure la valeur

B :
récompense les deux contributions
```

Cela évite de transformer B en simple programme de récompense de popularité.

---

# 24. Exemple

Un utilisateur publie un commentaire particulièrement pertinent.

Un autre utilisateur fait :

```text
Mise = 30 A
Conviction = C3
```

Le commentaire est ensuite soumis à une expérimentation.

Résultat :

```text
ContentScore(commentaire) élevé
CurationScore(curateur) élevé
```

Après règlement :

```text
Auteur du commentaire
→ B provenant du pool créateur

Curateur
→ B provenant du pool curateur
```

Mais si le commentaire devient populaire sans démontrer de valeur indépendante :

```text
ContentScore faible
```

alors la popularité ne suffit pas à créer du B.

Et si le curateur avait misé dessus mais que sa prédiction n'apporte aucune information :

```text
CurationScore faible
```

il ne reçoit pas automatiquement de B.

---

# 25. Le Like disparaît également des commentaires

La même logique UX peut être appliquée aux commentaires.

Au lieu de :

```text
❤️  42
💬  12
...
```

on peut avoir :

```text
Miser  18 A
```

Le geste principal est donc identique partout.

Cela réduit considérablement la charge cognitive :

```text
POST       → Miser
COMMENTAIRE → Miser
```

L'utilisateur n'a pas besoin d'apprendre deux systèmes différents.

---

# 26. B — monnaie de récompense

B est fondamentalement différente de A.

B est :

- earned-only ;
- non achetable ;
- non transférable ;
- non convertible ;
- sans retrait en monnaie réelle ;
- distribuée depuis une enveloppe périodique fixe ;
- utilisable uniquement dans le catalogue interne ;
- sans influence directe sur le ranking ou la curation.

B ne doit jamais devenir une seconde monnaie permettant d'acheter de l'influence.

---

# 27. Enveloppe B

Le système fonctionne avec une enveloppe périodique :

```text
E_B_total
=
E_B_créateur
+
E_B_curateur
+
E_B_réserve
```

Exemple de calibration initiale :

```text
50 % créateurs
40 % curateurs
10 % réserve
```

ou :

```text
60 % créateurs
30 % curateurs
10 % réserve
```

Ces ratios sont des paramètres économiques et peuvent être calibrés expérimentalement.

---

# 28. Deux pools distincts

Il est important de conserver deux pools.

### Pool créateur

Récompense :

```text
ContentScore
```

### Pool curateur

Récompense :

```text
CurationScore
```

Cela permet de répondre à deux questions différentes :

> Qui produit de la valeur ?

et :

> Qui sait identifier cette valeur ?

---

# 29. Plafonds

Des plafonds doivent empêcher qu'un événement exceptionnel ou une collusion absorbe une part disproportionnée du pool.

Exemples de paramètres initiaux :

```text
max B / post curateur
= 2 % du pool curateur
```

```text
max B / auteur créateur
= 1 % du pool créateur
```

Et un plafond quotidien par utilisateur peut également être appliqué.

---

# 30. Droits progressifs

Exemple de niveaux :

```text
Vérifié
→ 0 B/jour

Établi
→ 40 B/jour

Confirmé
→ 100 B/jour
```

Ces seuils doivent être calibrés avec les données réelles.

L'objectif est d'éviter qu'un nouveau compte puisse immédiatement exploiter toute la surface économique.

---

# 31. Anti-Sybil et anti-collusion

Les commentaires augmentent fortement la surface d'attaque.

Un attaquant pourrait créer :

```text
Compte A
  ↓
Commentaire
  ↓
Comptes B/C/D
  ↓
Mises A
  ↓
B
```

Le système doit donc considérer les graphes de comportement.

Signaux utiles :

- similarité comportementale ;
- synchronisation ;
- liens entre comptes ;
- historique des interactions ;
- concentration des mises ;
- réciprocité anormale ;
- vitesse de création de comptes ;
- patterns de curation ;
- relations auteur ↔ curateurs.

---

# 32. La récompense ne doit pas dépendre uniquement de l'engagement

C'est probablement la règle la plus importante.

Mauvais modèle :

```text
Commentaires
× likes
× vues
× mises
= B
```

Cela créerait immédiatement une compétition de popularité.

Modèle recherché :

```text
Valeur démontrée
× contribution marginale
× confiance statistique
× sécurité
= récompense
```

---

# 33. Règlement différé

B ne doit pas être frappé immédiatement après une mise.

Pipeline :

```text
Mise
↓
Observation
↓
Expérimentation
↓
Résultat
↓
Évaluation
↓
Fraud checks
↓
Settlement
↓
Mint B
```

Cela empêche les utilisateurs de connaître instantanément la récompense et d'optimiser directement leur comportement contre le système.

---

# 34. Économie fermée

B doit rester une économie fermée.

```text
A
 ─X→ B

B
 ─X→ A

B
 ─X→ argent réel

B
 ─X→ autre utilisateur
```

B peut uniquement être dépensée dans le catalogue interne prévu par le produit.

La valeur extractible du catalogue doit rester suffisamment faible pour que créer une ferme de comptes ne soit pas économiquement rentable.

---

# 35. Ce que B peut acheter

B peut être utilisée pour des éléments internes :

- cosmétiques ;
- personnalisation ;
- avatar ;
- marqueurs ;
- badges ;
- fonctionnalités internes ;
- éléments de personnalisation.

Mais :

```text
B ≠ influence
B ≠ ranking
B ≠ visibilité
B ≠ A
```

Cela protège la séparation entre récompense et pouvoir de curation.

---

# 36. Le système complet

```text
                       ┌───────────────┐
                       │    CONTENU    │
                       └───────┬───────┘
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
                 ▼                           ▼
              POST                       COMMENTAIRE
                 │                           │
                 │                           │
                 └─────────────┬─────────────┘
                               │
                               ▼
                         ┌───────────┐
                         │  MISE A   │
                         └─────┬─────┘
                               │
                    Conviction + montant
                               │
                               ▼
                  Expérimentation contrôlée
                               │
                ┌──────────────┴──────────────┐
                │                             │
                ▼                             ▼
          ContentScore                  CurationScore
                │                             │
                ▼                             ▼
        Pool B créateur                Pool B curateur
                │                             │
                ▼                             ▼
          Auteur du contenu                Curateur
```

---

# 37. Distinction fondamentale

Le système possède finalement quatre comportements économiques différents :

| Comportement | Objet | Mesure | Récompense |
|---|---|---|---|
| Création | Post/commentaire | ContentScore | B créateur |
| Curation | Post/commentaire | CurationScore | B curateur |
| Mise | A | Conviction + capacité engagée | Potentiellement B après résultat |
| Consommation | Contenu | — | — |

La mise est donc à la fois :

**une interaction UX**  
et  
**un mécanisme de curation algorithmique.**

---

# 38. Pourquoi cette architecture est cohérente avec un réseau ultra-fast

Le produit cherche à minimiser le nombre de décisions visibles.

Au lieu de demander :

> Est-ce que j'aime ?  
> Est-ce que je réagis ?  
> Est-ce que je recommande ?  
> Est-ce que je booste ?  
> Est-ce que je sauvegarde ?

l'interface peut avoir une action centrale :

> **Miser**

Le reste est secondaire.

Cela permet de conserver une expérience de consommation rapide tout en donnant une fonction économique et algorithmique au geste principal.

---

# 39. Risque principal du modèle

Le risque principal n'est pas l'absence de Like.

C'est que la mise devienne psychologiquement comprise comme :

> « acheter de la visibilité ».

Il faut donc que l'UX et le produit communiquent constamment la distinction :

```text
Je mise
≠
Je paie pour être visible

Je mise
=
Je signale une conviction que le système va tester
```

Le système doit également démontrer par son comportement que miser beaucoup ne garantit jamais la visibilité.

---

# 40. Déploiement recommandé

### Phase 1 — Infrastructure

Implémenter :

- A ;
- claims ;
- mises ;
- conviction ;
- journalisation ;
- cohortes ;
- ContentScore ;
- CurationScore ;
- règlement ;
- B.

### Phase 2 — Shadow mode

Calculer les scores sans afficher de récompenses.

Objectif :

> vérifier que le système produit des signaux cohérents avant de créer une économie visible.

### Phase 3 — Mises sur posts

Activer :

```text
Post → Miser
```

sans nécessairement activer immédiatement les récompenses B maximales.

### Phase 4 — Pool créateur

Activer progressivement :

```text
ContentScore → B créateur
```

### Phase 5 — Pool curateur

Activer :

```text
CurationScore → B curateur
```

### Phase 6 — Commentaires

Activer :

```text
Commentaire → Miser
```

Puis mesurer séparément :

```text
ContentScore(commentaire)
CurationScore(commentaire)
```

### Phase 7 — Récompense des curateurs de commentaires

Activer progressivement :

```text
CurationScore(commentaire)
→ B curateur
```

uniquement après validation de la robustesse du modèle.

---

# 41. Critères Go / No-Go

Avant une généralisation, le système doit notamment vérifier :

### Économie

- Une ferme de comptes simulée n'est pas rentable.
- La valeur extractible de B reste faible.
- Les pools ne sont pas capturés par quelques comptes.

### Curation

- Les mises précoces apportent réellement de l'information.
- La contribution marginale n'est pas dégénérée.
- La mise n'est pas simplement une nouvelle forme de Like.

### Commentaires

- Les commentaires utiles sont distingués des commentaires simplement populaires.
- Les curateurs de commentaires apportent une information supplémentaire.
- Les mécanismes de réciprocité et de collusion restent maîtrisables.

### UX

- Le temps de consommation du feed n'est pas fortement augmenté.
- Le bouton Miser est compris rapidement.
- Les utilisateurs n'ont pas besoin de comprendre toute la mécanique A/B pour utiliser l'application.

### Sécurité

- Sybil maîtrisé.
- Collusion maîtrisée.
- Multi-comptes maîtrisés.
- Manipulation des cohortes maîtrisée.

---

# 42. Modèle conceptuel final

La philosophie V5.3 peut être résumée ainsi :

```text
A = capacité de dire :
    « Je crois que ceci mérite d'être testé. »

Expérimentation =
    « Vérifions si cette conviction était utile. »

ContentScore =
    « Quelle valeur ce contenu a-t-il réellement apportée ? »

CurationScore =
    « Quelle valeur ce curateur a-t-il réellement apportée ? »

B =
    « Récompensons la valeur démontrée. »
```

Et cela fonctionne aussi bien pour :

```text
Post
    ↓
Miser
    ↓
ContentScore + CurationScore
```

que pour :

```text
Commentaire
    ↓
Miser
    ↓
ContentScore + CurationScore
```

avec deux bénéficiaires potentiels :

```text
Auteur → B créateur
Curateur → B curateur
```

---

# 43. Principe directeur

Le système ne doit jamais récompenser simplement :

> **« ce qui a attiré le plus d'attention »**

mais plutôt :

> **« ceux qui ont produit ou identifié une valeur que l'expérimentation a ensuite confirmée »**.

C'est cette distinction qui permet de transformer la mise A en **mécanisme de curation**, plutôt qu'en simple Like monétisé.