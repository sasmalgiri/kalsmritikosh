# Agent eval fair run 3 — six new real public cases (sources)

Added 2026-11-24 for the AI-50 fair run 3 (`AgentReaderEvalTests`, `.fair3` layout). Solved public matters the eval had never used. Each case folder holds only the documents the app imports (this file sits outside the case folders on purpose, and its name is unique because the test bundle flattens resources). Text is the publisher's own: HTML stripped; for DOJ releases the title and the issuing office/date line from the page were added on top, the trailing `###` / Twitter line dropped, and the site's encoding artefact `=s` restored to `’s`; for SEC releases the page navigation ("More in this Section", "SEC Complaint" links) was dropped; the CAP decision is caption + citation + head matter + opinion text from the CAP JSON; the NTSB first page is built from the database's coded fields (as `scripts/casebench/ntsb.py` does). Questions live in `KalsmritikoshTests/AgentReaderEvalTests.swift`; answer keys are kept outside the repository.

## real3-jha

DOJ (USAO Maryland) — Manoj Kumar Jha, Morgan State University professor: NSF STTR grant fraud through Amar Transportation Research and Consulting, Inc., and student-stipend kickbacks. Conviction (April 1, 2014) and sentencing (August 29, 2014) releases.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| jha-2014-04-01-press-release.txt | Morgan State University Professor Convicted In Scheme To Defraud The National Science Foundation And For Obtaining Kickbacks From Students’ Stipends | https://www.justice.gov/usao-md/pr/morgan-state-university-professor-convicted-scheme-defraud-national-science-foundation |
| jha-2014-08-29-press-release.txt | Morgan State University Professor Sentenced To 3 Years In Prison In Scheme To Defraud The National Science Foundation And For Obtaining Kickbacks From Student Stipends | https://www.justice.gov/usao-md/pr/morgan-state-university-professor-sentenced-3-years-prison-scheme-defraud-national |

## real3-archcoal

DOJ (USAO S.D. W.Va.) — Arch Coal Mountain Laurel Mining Complex kickback scheme (David Runyon, vendors Roeher/CM Supply, Porter/Quality Oil, Barnette/Mining Repair Specialist, Ellis and Herndon/Tri-State Mine Service, Griffith/NARCO, Lusk). Eleven plea and sentencing releases, July 2014 – February 2017.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| archcoal-2014-07-09-press-release.txt | Logan County Man Pleads Guilty To Tax Fraud In Connection With Arch Coal Kickback Scheme | https://www.justice.gov/usao-sdwv/pr/logan-county-man-pleads-guilty-tax-fraud-connection-arch-coal-kickback-scheme |
| archcoal-2014-07-10-press-release.txt | Logan Man Admits Involvement In Arch Coal Kickback Scheme | https://www.justice.gov/usao-sdwv/pr/logan-man-admits-involvement-arch-coal-kickback-scheme |
| archcoal-2014-07-14-press-release.txt | Men Plead Guilty To Lying About Roles In Arch Coal Kickback Scheme | https://www.justice.gov/usao-sdwv/pr/men-plead-guilty-lying-about-roles-arch-coal-kickback-scheme |
| archcoal-2014-07-16-press-release.txt | Logan County Men Admit Roles In Arch Coal Kickback Scheme | https://www.justice.gov/usao-sdwv/pr/logan-county-men-admit-roles-arch-coal-kickback-scheme |
| archcoal-2014-10-09-press-release.txt | Logan Businessman Sentenced For Tax Fraud Arising From Arch Coal Kickbacks | https://www.justice.gov/usao-sdwv/pr/logan-businessman-sentenced-tax-fraud-arising-arch-coal-kickbacks |
| archcoal-2015-02-03-press-release.txt | Logan County man sentenced for role in Arch Coal kickback scheme | https://www.justice.gov/usao-sdwv/pr/logan-county-man-sentenced-role-arch-coal-kickback-scheme |
| archcoal-2015-02-25-press-release.txt | Man sentenced for lying about role in Arch Coal kickback scheme | https://www.justice.gov/usao-sdwv/pr/man-sentenced-lying-about-role-arch-coal-kickback-scheme |
| archcoal-2015-04-22-press-release.txt | Logan County man sentenced for role in Arch Coal kickback scheme | https://www.justice.gov/usao-sdwv/pr/logan-county-man-sentenced-role-arch-coal-kickback-scheme-0 |
| archcoal-2015-06-30-press-release.txt | Former Arch Coal employee sentenced for lying about his role in kickback scheme | https://www.justice.gov/usao-sdwv/pr/former-arch-coal-employee-sentenced-lying-about-his-role-kickback-scheme |
| archcoal-2016-12-13-press-release.txt | Logan County man admits accepting kickbacks as an employee of a subsidiary of Arch Coal | https://www.justice.gov/usao-sdwv/pr/logan-county-man-admits-accepting-kickbacks-employee-subsidiary-arch-coal |
| archcoal-2017-02-08-press-release.txt | Logan County man sentenced for accepting kickbacks as an employee of a subsidiary of Arch Coal | https://www.justice.gov/usao-sdwv/pr/logan-county-man-sentenced-accepting-kickbacks-employee-subsidiary-arch-coal |

## real3-carpenter

DOJ (USAO E.D. Cal.) — Carissa Carpenter, Northern California movie studio investment scam. Indictment/arrest (November 6, 2014), guilty plea (July 12, 2018) and sentencing (November 16, 2018) releases.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| carpenter-2014-11-06-press-release.txt | Arrest Made In Ventura For $5 Million Movie Studio Construction Scam In Northern California | https://www.justice.gov/usao-edca/pr/arrest-made-ventura-5-million-movie-studio-construction-scam-northern-california |
| carpenter-2018-07-12-press-release.txt | Guilty Plea in Multimillion Dollar Movie Studio Construction Scam in Northern California | https://www.justice.gov/usao-edca/pr/guilty-plea-multimillion-dollar-movie-studio-construction-scam-northern-california |
| carpenter-2018-11-16-press-release.txt | Woman Behind Dixon, Vallejo Movie Studio Scams Sentenced to 6.5 Years in Prison | https://www.justice.gov/usao-edca/pr/woman-behind-dixon-vallejo-movie-studio-scams-sentenced-65-years-prison |

## real3-k2

SEC — SEC v. K2 Unlimited, Inc., 211 Ventures, LLC, Diane Glatfelter, Robert Rice and Robert Anderson, No. 1:11-cv-11649 (D. Mass.): complaint and the three judgment releases (LR-22098, LR-22649, LR-22971, LR-23199).

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| k2-litigation-release-22098.txt | SEC Litigation Release No. 22098 (September 19, 2011) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-22098 |
| k2-litigation-release-22649.txt | SEC Litigation Release No. 22649 (March 19, 2013) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-22649 |
| k2-litigation-release-22971.txt | SEC Litigation Release No. 22971 (April 11, 2014) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-22971 |
| k2-litigation-release-23199.txt | SEC Litigation Release No. 23199 (February 18, 2015) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-23199 |

## real3-valenti

Caselaw Access Project — United States v. Valenti, 60 F.3d 941 (2d Cir. 1995): treasurer's embezzlement from the Caravanserai Owners Association; conviction and sentence affirmed.

Licence: Public-domain court opinion; Caselaw Access Project data CC0

| File | Source document | URL |
|---|---|---|
| valenti-decision.txt | United States v. Valenti, 60 F.3d 941 (2d Cir. 1995-07-06) | https://static.case.law/f3d/60/cases/0941-01.json |

## real3-jfk

NTSB DCA24FA164 — runway incursion at JFK, April 17, 2024: Swiss flight 17K rejected takeoff on runway 4L while four aircraft crossed; final narratives, probable cause and coded fields.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| jfk-report-page-1.txt | NTSB DCA24FA164 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20240418194114); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24FA164) |
| jfk-factual.txt | NTSB DCA24FA164 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20240418194114); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24FA164) |
| jfk-analysis.txt | NTSB DCA24FA164 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20240418194114); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24FA164) |
| jfk-probable-cause.txt | NTSB DCA24FA164 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20240418194114); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24FA164) |
