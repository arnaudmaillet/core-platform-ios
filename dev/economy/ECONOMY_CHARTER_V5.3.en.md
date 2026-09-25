# A/B Economic Charter — V5.3
*English translation of `ECONOMY_CHARTER_V5.3.fr.md` (the French original is authoritative).*

## 1. General vision

SocialMap's economic system rests on two deliberately separate currencies:

- **A — curation capacity**: lets the user commit part of their curation capacity to a piece of content.
- **B — earned-only reward**: rewards, after the fact, the informational value demonstrated by a creator or a curator.

The goal is not to turn social engagement into a visibility market.

Rather, the system should turn part of users' attention into **economically committing curation signals**, and then pay only for behaviors whose value is demonstrated by a controlled experiment.

The fundamental principle is:

> **A expresses a conviction before the outcome. B rewards value demonstrated after the outcome.**

---

# 2. Why replace the Like with the A stake?

In an ultra-fast social network, every post must be consumable quickly.

An interface presenting all at once:

- Like
- reaction
- stake
- share
- save
- comment
- other actions

risks introducing too many choices and slowing consumption down.

The V5.3 decision is therefore **not to keep the Like as the main interaction**.

The stake becomes the central action on content.

### UX model

```text
Consume the content
        │
        ▼
     [ Stake ]
        │
        ├── quick stake
        │
        └── advanced options
              ├── conviction
              └── amount
```

The user therefore does not need to understand the whole economy to use the product.

The main gesture simply becomes:

> **"This content deserves more experimental attention from the platform."**

---

# 3. A stake does not simply mean "I like it"

Removing the Like implies an important distinction.

The system no longer explicitly measures a light preference of the kind:

> "I like this content."

The stake measures something stronger:

> "I think this content deserves to be tested / discovered more by the platform."

This difference is intentional.

The A stake is therefore a **committing recommendation signal**, not a mere emotional reaction.

This gives the product an extremely simple grammar:

| Action | Meaning |
|---|---|
| No gesture | I am consuming |
| **A stake** | I think this content deserves more experimentation |
| Comment | I am adding something to the discussion |
| Share | I am recommending this content directly to someone |
| Save, if kept | I want to be able to find it again |

The stake does not need to replace every other social action.

It mainly replaces **the Like as the main support button**.

---

# 4. A — Curation capacity

## 4.1 Nature

A is a curation capacity distributed to users.

A is:

- not purchasable;
- not transferable;
- not convertible into B;
- non-expiring;
- capped;
- distributed through claim mechanisms;
- spent when a curation is committed.

Example cap:

```text
A_max = 2,000 A
```

The exact amount remains a calibration parameter.

---

# 5. Why A is not a conventional currency

A must not be perceived as internal money.

A user must not be able to reason:

> "I have a lot of A, so I can buy visibility."

On the contrary:

> "I have a limited capacity to express my curation convictions."

The difference is fundamental.

**A never directly buys visibility.**

A stake only triggers a possibility of experimentation.

---

# 6. Two independent dimensions: conviction and stake

A curation has two dimensions.

### Conviction

Discrete level:

```text
C1
C2
C3
C4
```

Each level corresponds to an implied probability `p_i`.

Initial example:

```text
C1 = 0.25
C2 = 0.40
C3 = 0.60
C4 = 0.80
```

These values are parameters to calibrate, not fixed economic truths.

### Stake

The A amount represents the quantity of capacity the user agrees to commit.

The stake must not directly determine the probability.

Thus:

```text
Conviction → implied probability
A stake    → quantity of capacity committed
```

and not:

```text
A stake → probability
```

This prevents a user rich in A from mechanically turning their influence into certainty.

---

# 7. Stake UX

To preserve the product's ultra-fast character, the user should not be required to go through four conviction levels and several amounts on every post.

The interface can favor:

### Quick stake

```text
[Stake]
```

with a default value.

### Advanced stake

Available as a secondary option:

```text
Amount: 20 A
Conviction: C3
```

This keeps the interaction extremely fast while leaving advanced users the possibility of expressing a precise conviction.

---

# 8. A post's curation pipeline

```text
POST
  │
  ▼
Prediction frozen at t0
  │
  ├───────────────┐
  ▼               ▼
Control cohort   Test cohort
  │               │
  │          A stakes
  │               │
  └───────┬───────┘
          ▼
Controlled experimentation
          │
          ▼
Independent outcome Z_P
          │
          ├───────────────┐
          ▼               ▼
     ContentScore    CurationScore
          │               │
          ▼               ▼
  Creator B pool    Curator B pool
```

The essential point is that the stake does not itself create its own outcome.

---

# 9. Control cohort

The control cohort must remain independent of A signals.

The curator's prediction is frozen at the moment of curation:

```text
π_before_i
```

The system then assigns an independent outcome:

```text
Z_P
```

For example:

> does the content ultimately land in the top 15% by ContentScore in a control cohort?

The system must not simply measure:

> "The post got a lot of views after getting a lot of stakes."

That would create a circular loop.

---

# 10. Measuring prediction quality

In V1, a Brier Score approach can be used.

```text
PredictionValue
= Brier(π_before_i, Z_P)
  - Brier(baseline, Z_P)
```

or, depending on the chosen convention:

```text
PredictionValue
= Brier(π_before_i, Z_P)
  - Brier(reference, Z_P)
```

Then:

```text
PredictionScore
= max(0, PredictionValue)
```

The goal is to measure whether the curator contributed useful predictive information relative to a reference.

---

# 11. CurationScore

The curator's score must not be a mere function of popularity.

Model:

```text
RawInformationScore
=
PredictionScore
× MarginalContribution
× TemporalUtility
× EvidenceConfidence
× StakeFactor
```

Then:

```text
SafetyAdjustment
=
Trust
× AntiFraud
× Relationship
```

Finally:

```text
CurationScore
=
RawInformationScore
× SafetyAdjustment
```

---

# 12. PredictionScore

Measures the quality of the curator's prediction.

A user who stakes correctly on a piece of content before its quality is known can generate a useful signal.

A user who systematically stakes on content that is already obviously popular must not get the same value.

---

# 13. MarginalContribution

The system must try to measure the **curator's additional value**.

It is not enough that several people made the same prediction.

A signal must bring information.

An initial approximation can combine:

```text
Uncertainty reduction
× independence
× coverage
```

A later evolution could use:

- leave-one-out;
- Shapley value;
- marginal attribution methods.

The goal remains the same:

> reward the informational contribution, not the number of people who did the same thing.

---

# 14. TemporalUtility

Earliness can have value.

Identifying an interesting piece of content early can be more useful than identifying the same content after it has already become obvious.

But timing must be bounded.

Curation must not be turned into:

> "First to arrive = best curator."

Earliness is therefore one factor among others.

---

# 15. EvidenceConfidence

An outcome observed on very little data must not carry the same weight as a statistically robust outcome.

The system must therefore take into account the confidence in the evaluation.

This limits excessive rewards caused by random events.

---

# 16. SafetyAdjustment

The score must also include protections:

```text
Trust
× AntiFraud
× Relationship
```

### Trust

The curator's behavioral history.

### AntiFraud

Detection of:

- Sybil;
- multi-accounting;
- bots;
- collusion;
- coordinated manipulation.

### Relationship

A possible reduction of a signal's value when there is a relationship likely to strongly bias the curation.

---

# 17. Comments: same system, new context

The same logic can be applied to comments.

A comment also becomes a curatable object.

The user can therefore:

```text
Post
 └── Stake

Comment
 └── Stake
```

This gives the app an extremely consistent grammar:

> **Staking = signaling that an item deserves more attention.**

---

# 18. What does staking on a comment mean?

The meaning must, however, differ from the post.

### Stake on a post

> "This content deserves more experimentation and discovery."

### Stake on a comment

> "This contribution brings particular value to the discussion."

The comment is therefore evaluated in the context of the conversation.

---

# 19. A comment must not automatically boost the post

The two objects must be kept separate.

```text
Post
 └── ContentScore(post)

Comment
 └── ContentScore(comment)
```

A stake on a comment must mainly act on the comment's visibility and evaluation.

It must not automatically raise the parent post's score.

Otherwise a viral comment could artificially lift an original piece of content that has not itself demonstrated its quality.

---

# 20. A comment's ContentScore

The comment must have its own `ContentScore`.

It can measure, among other things:

- informational contribution;
- relevance;
- quality of the discussion;
- marginal contribution;
- reliability;
- diversity of information;
- quality of the exchanges generated;
- absence of manipulation.

The mere number of replies or reactions is not sufficient.

---

# 21. B reward for the comment's author

The system can treat a comment as a creative piece of content in its own right.

Thus:

```text
Comment
      │
      ▼
ContentScore
      │
      ▼
Creator B pool
      │
      ▼
Comment author
```

A comment's author can therefore receive B if their contribution demonstrates sufficient informational value.

---

# 22. B reward for the comment's curator

This is also possible.

The curation of a comment is evaluated separately:

```text
Comment
      │
      ├───────────────┐
      ▼               ▼
ContentScore     CurationScore
      │               │
      ▼               ▼
Author            Curator
      │               │
      ▼               ▼
Creator pool      Curator pool
      │               │
      └───────┬───────┘
              ▼
              B
```

Thus:

- **the comment's author** is rewarded for the value of their contribution;
- **the curator** is rewarded for having correctly identified that value.

The two behaviors are therefore distinct.

---

# 23. Why reward both?

This creates an interesting loop:

```text
Creator:
produces value

Curator:
identifies value

System:
measures value

B:
rewards both contributions
```

This keeps B from turning into a mere popularity reward program.

---

# 24. Example

A user publishes a particularly relevant comment.

Another user does:

```text
Stake = 30 A
Conviction = C3
```

The comment is then put through an experiment.

Outcome:

```text
ContentScore(comment) high
CurationScore(curator) high
```

After settlement:

```text
Comment author
→ B from the creator pool

Curator
→ B from the curator pool
```

But if the comment becomes popular without demonstrating independent value:

```text
ContentScore low
```

then popularity is not enough to create B.

And if the curator had staked on it but their prediction brings no information:

```text
CurationScore low
```

they do not automatically receive B.

---

# 25. The Like also disappears from comments

The same UX logic can be applied to comments.

Instead of:

```text
❤️  42
💬  12
...
```

we can have:

```text
Stake  18 A
```

The main gesture is therefore the same everywhere.

This considerably reduces cognitive load:

```text
POST    → Stake
COMMENT → Stake
```

The user does not need to learn two different systems.

---

# 26. B — reward currency

B is fundamentally different from A.

B is:

- earned-only;
- not purchasable;
- not transferable;
- not convertible;
- not withdrawable as real money;
- distributed from a fixed periodic envelope;
- usable only in the internal catalog;
- without direct influence on ranking or curation.

B must never become a second currency for buying influence.

---

# 27. B envelope

The system works with a periodic envelope:

```text
E_B_total
=
E_B_creator
+
E_B_curator
+
E_B_reserve
```

Example of an initial calibration:

```text
50% creators
40% curators
10% reserve
```

or:

```text
60% creators
30% curators
10% reserve
```

These ratios are economic parameters and can be calibrated experimentally.

---

# 28. Two distinct pools

It is important to keep two pools.

### Creator pool

Rewards:

```text
ContentScore
```

### Curator pool

Rewards:

```text
CurationScore
```

This makes it possible to answer two different questions:

> Who produces value?

and:

> Who knows how to identify that value?

---

# 29. Caps

Caps must prevent an exceptional event or collusion from absorbing a disproportionate share of the pool.

Examples of initial parameters:

```text
max B / post (curator)
= 2% of the curator pool
```

```text
max B / author (creator)
= 1% of the creator pool
```

A daily cap per user can also be applied.

---

# 30. Progressive entitlements

Example levels:

```text
Verified
→ 0 B/day

Established
→ 40 B/day

Confirmed
→ 100 B/day
```

These thresholds must be calibrated with real data.

The goal is to prevent a new account from immediately exploiting the entire economic surface.

---

# 31. Anti-Sybil and anti-collusion

Comments greatly increase the attack surface.

An attacker could create:

```text
Account A
  ↓
Comment
  ↓
Accounts B/C/D
  ↓
A stakes
  ↓
B
```

The system must therefore consider behavior graphs.

Useful signals:

- behavioral similarity;
- synchronization;
- links between accounts;
- interaction history;
- concentration of stakes;
- abnormal reciprocity;
- account creation velocity;
- curation patterns;
- author ↔ curator relationships.

---

# 32. The reward must not depend solely on engagement

This is probably the most important rule.

Wrong model:

```text
Comments
× likes
× views
× stakes
= B
```

That would immediately create a popularity contest.

Target model:

```text
Demonstrated value
× marginal contribution
× statistical confidence
× safety
= reward
```

---

# 33. Deferred settlement

B must not be minted immediately after a stake.

Pipeline:

```text
Stake
↓
Observation
↓
Experimentation
↓
Outcome
↓
Evaluation
↓
Fraud checks
↓
Settlement
↓
Mint B
```

This prevents users from knowing the reward instantly and from directly optimizing their behavior against the system.

---

# 34. Closed economy

B must remain a closed economy.

```text
A
 ─X→ B

B
 ─X→ A

B
 ─X→ real money

B
 ─X→ another user
```

B can only be spent in the internal catalog provided by the product.

The value extractable from the catalog must stay low enough that building an account farm is not economically profitable.

---

# 35. What B can buy

B can be used for internal items:

- cosmetics;
- customization;
- avatar;
- markers;
- badges;
- internal features;
- customization items.

But:

```text
B ≠ influence
B ≠ ranking
B ≠ visibility
B ≠ A
```

This protects the separation between reward and curation power.

---

# 36. The complete system

```text
                       ┌───────────────┐
                       │    CONTENT    │
                       └───────┬───────┘
                               │
                 ┌─────────────┴─────────────┐
                 │                           │
                 ▼                           ▼
              POST                        COMMENT
                 │                           │
                 │                           │
                 └─────────────┬─────────────┘
                               │
                               ▼
                         ┌───────────┐
                         │  A STAKE  │
                         └─────┬─────┘
                               │
                     Conviction + amount
                               │
                               ▼
                  Controlled experimentation
                               │
                ┌──────────────┴──────────────┐
                │                             │
                ▼                             ▼
          ContentScore                  CurationScore
                │                             │
                ▼                             ▼
         Creator B pool                Curator B pool
                │                             │
                ▼                             ▼
         Content author                    Curator
```

---

# 37. Fundamental distinction

In the end, the system has four different economic behaviors:

| Behavior | Object | Measure | Reward |
|---|---|---|---|
| Creation | Post/comment | ContentScore | Creator B |
| Curation | Post/comment | CurationScore | Curator B |
| Stake | A | Conviction + committed capacity | Potentially B after the outcome |
| Consumption | Content | — | — |

The stake is therefore both:

**a UX interaction**  
and  
**an algorithmic curation mechanism.**

---

# 38. Why this architecture is consistent with an ultra-fast network

The product seeks to minimize the number of visible decisions.

Instead of asking:

> Do I like it?  
> Do I react?  
> Do I recommend it?  
> Do I boost it?  
> Do I save it?

the interface can have one central action:

> **Stake**

Everything else is secondary.

This keeps the consumption experience fast while giving the main gesture an economic and algorithmic function.

---

# 39. The model's main risk

The main risk is not the absence of a Like.

It is that the stake comes to be psychologically understood as:

> "buying visibility".

The UX and the product must therefore constantly communicate the distinction:

```text
I stake
≠
I pay to be visible

I stake
=
I signal a conviction that the system will test
```

The system must also demonstrate through its behavior that staking a lot never guarantees visibility.

---

# 40. Recommended rollout

### Phase 1 — Infrastructure

Implement:

- A;
- claims;
- stakes;
- conviction;
- logging;
- cohorts;
- ContentScore;
- CurationScore;
- settlement;
- B.

### Phase 2 — Shadow mode

Compute the scores without displaying rewards.

Goal:

> verify that the system produces consistent signals before creating a visible economy.

### Phase 3 — Stakes on posts

Enable:

```text
Post → Stake
```

without necessarily enabling maximum B rewards right away.

### Phase 4 — Creator pool

Progressively enable:

```text
ContentScore → creator B
```

### Phase 5 — Curator pool

Enable:

```text
CurationScore → curator B
```

### Phase 6 — Comments

Enable:

```text
Comment → Stake
```

Then measure separately:

```text
ContentScore(comment)
CurationScore(comment)
```

### Phase 7 — Rewarding comment curators

Progressively enable:

```text
CurationScore(comment)
→ curator B
```

only after the model's robustness has been validated.

---

# 41. Go / No-Go criteria

Before a general rollout, the system must verify, among other things:

### Economy

- A simulated account farm is not profitable.
- B's extractable value stays low.
- The pools are not captured by a handful of accounts.

### Curation

- Early stakes genuinely bring information.
- The marginal contribution is not degenerate.
- The stake is not simply a new form of Like.

### Comments

- Useful comments are distinguished from merely popular ones.
- Comment curators bring additional information.
- Reciprocity and collusion mechanisms remain under control.

### UX

- Feed consumption time is not significantly increased.
- The Stake button is understood quickly.
- Users do not need to understand the whole A/B mechanism to use the app.

### Security

- Sybil under control.
- Collusion under control.
- Multi-accounting under control.
- Cohort manipulation under control.

---

# 42. Final conceptual model

The V5.3 philosophy can be summed up as follows:

```text
A = the capacity to say:
    "I believe this deserves to be tested."

Experimentation =
    "Let's check whether this conviction was useful."

ContentScore =
    "What value did this content actually bring?"

CurationScore =
    "What value did this curator actually bring?"

B =
    "Let's reward the demonstrated value."
```

And this works just as well for:

```text
Post
    ↓
Stake
    ↓
ContentScore + CurationScore
```

as for:

```text
Comment
    ↓
Stake
    ↓
ContentScore + CurationScore
```

with two potential beneficiaries:

```text
Author  → creator B
Curator → curator B
```

---

# 43. Guiding principle

The system must never simply reward:

> **"whatever drew the most attention"**

but rather:

> **"those who produced or identified value that experimentation then confirmed"**.

It is this distinction that turns the A stake into a **curation mechanism**, rather than a mere monetized Like.
