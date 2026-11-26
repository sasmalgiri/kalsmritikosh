# Agent eval fair run 5 — six new international public cases (sources and licences)

Added 2026-11-25 for the AI-50 fair run 5 (`AgentReaderEvalTests`, `.fair5` layout; owner: "it should work for any case"). Solved public matters from the UK, Australia and the EU that the eval had never used (none of their names occurs anywhere else in the repository): pounds, Australian dollars and euros (incl. "€ 1 494 302 000" space-grouped figures), day-first dates ("16 January 2026", "28 Mar 2025"), UK/Australian/EU naming. Each case folder holds only the documents the app imports (this file sits outside the case folders on purpose, and its name is unique because the test bundle flattens resources). Text is the publisher's own, HTML stripped, tables written one row per line with " | " between cells. Fetched 2026-11-25: gov.uk pages from the GOV.UK Content API (`https://www.gov.uk/api/content/<path>`, `details.body`), with the title, the issuing body and the first-published date (case page: last-updated date) added on top, followed by the page's own summary line; ASIC pages from the page's main content (`<main>`), with the title and the release number added on top (the pages carry no publication date in their text; none was added) and the "Downloads – Judgment" link line dropped; EC releases from the Press Corner API (`/commission/presscorner/api/documents?reference=…&language=EN`, `htmlContent`), with the reference (and for IP/16/4304 the title and "Brussels, 7 December 2016") added on top. India: no matter with a clearly open licence on the release text was found (data.gov.in GODL covers datasets, not press releases), so a second ASIC case was used instead. Questions live in `KalsmritikoshTests/AgentReaderEvalTests.swift`; answer keys are kept outside the repository.

## intl5-cook

Serious Fraud Office — Jeffrey Cook, former Ministry of Defence official, convicted of misconduct in public office (secret payments from ME Consultants Ltd on the SANGCOM project; GPT Special Project Management Ltd prosecuted in 2021). Conviction (6 March 2024) and sentencing (12 April 2024) releases.

Licence: Open Government Licence v3.0 (https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/). Attribution: "Contains public sector information licensed under the Open Government Licence v3.0."

| File | Source document | URL |
|---|---|---|
| cook-2024-03-06-sfo-press-release.txt | Former MoD official convicted for taking £70k in secret kickbacks (SFO, 6 March 2024) | https://www.gov.uk/government/news/former-mod-official-convicted-for-taking-70k-in-secret-kickbacks |
| cook-2024-04-12-sfo-press-release.txt | Former MoD official jailed for taking £70k in kickbacks (SFO, 12 April 2024) | https://www.gov.uk/government/news/former-mod-official-jailed-for-taking-70k-in-kickbacks |

## intl5-ethical

Serious Fraud Office — Ethical Forestry Limited: directors Matthew Pickard, Stephen Greenaway and Paul Laver, £70 million tree-planting (Costa Rica) pension investment fraud. Conviction release (16 January 2026), sentencing release (3 September 2026) and the SFO case page (last updated 30 September 2026).

Licence: Open Government Licence v3.0 (https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/). Attribution: "Contains public sector information licensed under the Open Government Licence v3.0."

| File | Source document | URL |
|---|---|---|
| ethical-2026-01-16-sfo-press-release.txt | SFO secures three convictions for £70 million investment fraud (SFO, 16 January 2026) | https://www.gov.uk/government/news/sfo-secures-three-convictions-for-70-million-investment-fraud |
| ethical-2026-09-03-sfo-press-release.txt | Prison for directors behind £70 million investment fraud (SFO, 3 September 2026) | https://www.gov.uk/government/news/prison-for-directors-behind-70-million-investment-fraud |
| ethical-sfo-case-page.txt | Ethical Forestry Limited — SFO case page | https://www.gov.uk/sfo-cases/ethical-forestry-limited |

## intl5-barclays

The Insolvency Service — £13.9 million unauthorised Barclays overdraft scheme: director disqualifications of Scott Dylan and David Antrobus (18 December 2025), Jack Mason (30 March 2026) and Daryl Dylan (27 July 2026). The July 2026 release spells the company names "Oldcocdt" / "Oldcostl" as published.

Licence: Open Government Licence v3.0 (https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/). Attribution: "Contains public sector information licensed under the Open Government Licence v3.0."

| File | Source document | URL |
|---|---|---|
| barclays-2025-12-18-insolvency-service-press-release.txt | Business partners who exploited banking system by channelling £13.9 million in unauthorised overdrafts through companies banned for combined 23 years (18 December 2025) | https://www.gov.uk/government/news/business-partners-who-exploited-banking-system-by-channelling-139-million-in-unauthorised-overdrafts-through-companies-banned-for-combined-23-years |
| barclays-2026-03-30-insolvency-service-press-release.txt | Businessman who remains in Spain despite prison sentence banned as company director (30 March 2026) | https://www.gov.uk/government/news/businessman-who-remains-in-spain-despite-prison-sentence-banned-as-company-director |
| barclays-2026-07-27-insolvency-service-press-release.txt | Fourth company director disqualified for role in £13.9 million Barclays ‘scam’ (27 July 2026) | https://www.gov.uk/government/news/fourth-company-director-disqualified-for-role-in-139-million-barclays-scam |

## intl5-berndale

ASIC — Berndale Capital Securities Pty Ltd: former directors Stavro D’Amore and Daniel Kirby, charged 2 June 2023; Kirby plea and sentence (2024–2025); D’Amore plea and sentence (2026). Five media releases, each with its editor’s notes as published.

Licence: Creative Commons Attribution 4.0 International (CC BY 4.0), which ASIC applies to "Media releases and other Newsroom information" (https://www.asic.gov.au/copyright/, checked 2026-11-25: verbatim reproduction permitted with acknowledgement). Attribution: "© Australian Securities & Investments Commission: Reproduced with permission." Reproduced verbatim (text only; no logo).

| File | Source document | URL |
|---|---|---|
| berndale-asic-23-143mr.txt | 23-143MR Former Berndale directors charged over dishonest conduct, misuse of company funds | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2023-releases/23-143mr-former-berndale-directors-charged-over-dishonest-conduct-misuse-of-company-funds |
| berndale-asic-24-204mr.txt | 24-204MR Former Berndale director pleads guilty to dishonest conduct and misuse of company funds | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2024-releases/24-204mr-former-berndale-director-pleads-guilty-to-dishonest-conduct-and-misuse-of-company-funds |
| berndale-asic-25-135mr.txt | 25-135MR Former Berndale director sentenced for dishonest conduct and misuse of company funds | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2025-releases/25-135mr-former-berndale-director-sentenced-for-dishonest-conduct-and-misuse-of-company-funds |
| berndale-asic-26-088mr.txt | 26-088MR Former Berndale director Stavro D’Amore pleads guilty to dishonest conduct and misusing nearly $700,000 in company funds | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2026-releases/26-088mr-former-berndale-director-stavro-d-amore-pleads-guilty-to-dishonest-conduct-and-misusing-nearly-700-000-in-company-funds |
| berndale-asic-26-182mr.txt | 26-182MR Stavro D’Amore jailed for misusing nearly $700,000 in Berndale funds | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2026-releases/26-182mr-stavro-d-amore-jailed-for-misusing-nearly-700-000-in-berndale-funds |

## intl5-siddiqui

ASIC — Usman Siddiqui, sole director of Equitable Financial Solutions Pty Ltd (in liquidation): travel restraint orders (2022), charges (2023, with editor’s notes to June 2026) and sentence (August 2026). The 26-187MR text writes “Mt Siddiqui” once, as published.

Licence: Creative Commons Attribution 4.0 International (CC BY 4.0), which ASIC applies to "Media releases and other Newsroom information" (https://www.asic.gov.au/copyright/, checked 2026-11-25: verbatim reproduction permitted with acknowledgement). Attribution: "© Australian Securities & Investments Commission: Reproduced with permission." Reproduced verbatim (text only; no logo).

| File | Source document | URL |
|---|---|---|
| siddiqui-asic-22-317mr.txt | 22-317MR Federal Court makes travel restraint orders against Usman Siddiqui | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2022-releases/22-317mr-federal-court-makes-travel-restraint-orders-against-usman-siddiqui |
| siddiqui-asic-23-322mr.txt | 23-322MR Director charged with breach of director duty offences | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2023-releases/23-322mr-director-charged-with-breach-of-director-duty-offences |
| siddiqui-asic-26-187mr.txt | 26-187MR Former NSW Director Usman Siddiqui jailed for dishonest use of position as director | https://www.asic.gov.au/about-asic/news-centre/find-a-media-release/2026-releases/26-187mr-former-nsw-director-usman-siddiqui-jailed-for-dishonest-use-of-position-as-director |

## intl5-eurocartel

European Commission (DG Competition) — euro interest rate derivatives (EIRD, case AT.39914) cartel: 2013 settlement decision (with the yen YIRD cartels; amended version of the release, footnote on the 6 April 2016 amendment of Société Générale’s fine) and the 2016 decision on Crédit Agricole, HSBC and JPMorgan Chase.

Licence: Commission Decision 2011/833/EU of 12 December 2011 on the reuse of Commission documents (reuse authorised provided the source is acknowledged). Attribution: "Source: European Commission press releases IP/13/1208 and IP/16/4304, © European Union, 2013 and 2016."

| File | Source document | URL |
|---|---|---|
| eird-2013-12-04-ec-press-release-ip-13-1208.txt | IP/13/1208 (AMENDED) Antitrust: Commission fines banks € 1.49 billion for participating in cartels in the interest rate derivatives industry (Brussels, 4 December 2013) | https://ec.europa.eu/commission/presscorner/detail/en/IP_13_1208 |
| eird-2016-12-07-ec-press-release-ip-16-4304.txt | IP/16/4304 Antitrust: Commission fines Crédit Agricole, HSBC and JPMorgan Chase € 485 million for euro interest rate derivatives cartel (Brussels, 7 December 2016) | https://ec.europa.eu/commission/presscorner/detail/en/IP_16_4304 |
