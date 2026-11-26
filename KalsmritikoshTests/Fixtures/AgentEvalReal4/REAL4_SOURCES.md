# Agent eval fair run 4 — six new real public cases (sources)

Added 2026-11-25 for the AI-50 fair run 4 (`AgentReaderEvalTests`, `.fair4` layout). Solved public matters the eval had never used (none of their names occurs anywhere else in the repository). Each case folder holds only the documents the app imports (this file sits outside the case folders on purpose, and its name is unique because the test bundle flattens resources). Text is the publisher's own: HTML stripped; for DOJ releases (justice.gov press-release API, `body` field) the title and the issuing office/date line from the release were added on top and a trailing `###` dropped; for SEC releases the page navigation ("More in this Section", "SEC Complaint" links) was dropped; for CFTC releases see the case note; the CAP decision is caption + citation + head matter + opinion texts from the CAP JSON; the NTSB first page is built from the database's coded fields and the narratives are copied with the same field-to-file mapping as real3-jfk (factual = narr_accf, analysis = narr_accp, probable cause = narr_cause). Questions live in `KalsmritikoshTests/AgentReaderEvalTests.swift`; answer keys are kept outside the repository.

## real4-newark

DOJ (USAO New Jersey) — Newark Watershed Conservation and Development Corporation (NWCDC) kickback scheme: Donald Bernard Sr. (special projects manager), executive director Linda Watkins Brashear, contractors James Porter (Jim P. Enterprises, New Beginnings Environmental Services) and Giacomo “Jack” DeRosa (Essex Home Improvements). Seven releases: indictment (December 15, 2014), three pleas (January 22, 2015; December 21, 2015; January 5, 2016) and three sentencings (July 13, July 20 and September 22, 2017). Not used: the five releases about other contractors and a consultant (2016-06-06, 2016-07-11, 2017-07-26, 2018-01-29, 2018-09-18) and the 2020-02-24 trial verdict.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| nwcdc-2014-12-15-press-release.txt | Former Newark Watershed Conservation and Development Official Indicted in Kickback Scheme, Money Laundering | https://www.justice.gov/usao-nj/pr/former-newark-watershed-conservation-and-development-official-indicted-kickback-scheme |
| nwcdc-2015-01-22-press-release.txt | Newark Watershed Conservation and Development Corp. Contractor Admits Role in Bribery Scheme | https://www.justice.gov/usao-nj/pr/newark-watershed-conservation-and-development-corp-contractor-admits-role-bribery-scheme |
| nwcdc-2015-12-21-press-release.txt | Former Executive Director Of Newark Watershed Conservation And Development Corporation Admits Role In Nearly $1 Million Kickback And Fraud Scheme | https://www.justice.gov/usao-nj/pr/former-executive-director-newark-watershed-conservation-and-development-corporation |
| nwcdc-2016-01-05-press-release.txt | Former Newark Watershed Conservation Official And Former Contractor Admit Roles In Bribery And Kickback Scheme | https://www.justice.gov/usao-nj/pr/former-newark-watershed-conservation-official-and-former-contractor-admit-roles-bribery |
| nwcdc-2017-07-13-press-release.txt | Former Newark Watershed Conservation Official Sentenced to Eight Years in Prison in Bribery and Kickback Scheme | https://www.justice.gov/usao-nj/pr/former-newark-watershed-conservation-official-sentenced-eight-years-prison-bribery-and |
| nwcdc-2017-07-20-press-release.txt | Newark Watershed Conservation And Development Corp. Contractor Gets Two Years In Jail For Role In Bribery Scheme | https://www.justice.gov/usao-nj/pr/newark-watershed-conservation-and-development-corp-contractor-gets-two-years-jail-role |
| nwcdc-2017-09-22-press-release.txt | Former Executive Director Of Newark Watershed Conservation And Development Corp. Sentenced To 102 Months In Prison For Role In Nearly $1 Million Kickback And Fraud Scheme | https://www.justice.gov/usao-nj/pr/former-executive-director-newark-watershed-conservation-and-development-corp-sentenced |

## real4-leondi

DOJ (USAO New Jersey) — Kevin Leondi, U.S. Army Contracting Command New Jersey employee: bribes from George Grassie and James Conway and kickbacks steered from Grassie to Conway on Picatinny Arsenal and Fort Dix construction work. Complaint/arrest (March 22, 2017), indictment (December 7, 2017), guilty plea (October 22, 2018) and sentencing (May 1, 2019) releases. The 2017 titles and texts spell the arsenal “Picattiny” as published.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| leondi-2017-03-22-press-release.txt | U.S. Army Employee At Picattiny Arsenal Charged With Conspiracy To Defraud The United States And To Accept Bribes | https://www.justice.gov/usao-nj/pr/us-army-employee-picattiny-arsenal-charged-conspiracy-defraud-united-states-and-accept |
| leondi-2017-12-07-press-release.txt | U.S. Army Employee at Picattiny Arsenal Indicted for Conspiring to Defraud the United States, Engaging in Kickback Scheme, Traveling to Promote Bribery and Obstructing Justice | https://www.justice.gov/usao-nj/pr/us-army-employee-picattiny-arsenal-indicted-conspiring-defraud-united-states-engaging |
| leondi-2018-10-22-press-release.txt | Former U.S. Army Employee At Picatinny Arsenal Admits Receiving Bribes And Directing Kickbacks | https://www.justice.gov/usao-nj/pr/former-us-army-employee-picatinny-arsenal-admits-receiving-bribes-and-directing-kickbacks |
| leondi-2019-05-01-press-release.txt | Former U.S. Army Employee at Picatinny Arsenal Sentenced to Five Years in Prison for Receiving Bribes and Directing Kickbacks | https://www.justice.gov/usao-nj/pr/former-us-army-employee-picatinny-arsenal-sentenced-five-years-prison-receiving-bribes |

## real4-mayfield

SEC — SEC v. MayfieldGentry Realty Advisors, LLC, et al., No. 13-cv-12520 (E.D. Mich.): Chauncey C. Mayfield's theft of about $3.1 million from the Police and Fire Retirement System of the City of Detroit and four executives' cover-up. Complaint release and the two judgment releases (LR-22720, LR-23176, LR-23581).

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| mayfieldgentry-litigation-release-22720.txt | SEC Litigation Release No. 22720 (June 10, 2013) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-22720 |
| mayfieldgentry-litigation-release-23176.txt | SEC Litigation Release No. 23176 (January 22, 2015) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-23176 |
| mayfieldgentry-litigation-release-23581.txt | SEC Litigation Release No. 23581 (June 23, 2016) | https://www.sec.gov/enforcement-litigation/litigation-releases/lr-23581 |

## real4-4x

CFTC — CFTC v. 4X Solutions, Inc. and Whileon Chay (S.D.N.Y.): forex commodity-pool Ponzi scheme. Complaint release 6559-13 (April 8, 2013) and judgment release 7321-16 (February 8, 2016). Text from the release header line to the staff line; page navigation, the media contact and the trailing fraud-advisory boilerplate dropped. cftc.gov rate-limited the 2013 page, so its text was taken from the Internet Archive's copy of the same cftc.gov URL.

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| 4x-2013-04-08-cftc-release-6559-13.txt | CFTC Press Release 6559-13 (April 8, 2013): CFTC Charges New York Firm 4X Solutions, Inc. and its Principal, Whileon Chay, with Forex Fraud Ponzi Scheme | https://www.cftc.gov/PressRoom/PressReleases/pr6559-13 (text from the Internet Archive copy: https://web.archive.org/web/2017/http://www.cftc.gov/PressRoom/PressReleases/pr6559-13) |
| 4x-2016-02-08-cftc-release-7321-16.txt | CFTC Press Release 7321-16 (February 8, 2016): Federal Court Orders New York Firm 4X Solutions, Inc. and Its Principal, Whileon Chay, to Pay More than $10 Million in Disgorgement and a Civil Monetary Penalty for Forex Fraud Ponzi Scheme | https://www.cftc.gov/PressRoom/PressReleases/7321-16 |

## real4-stoddard

Caselaw Access Project — United States v. Stoddard, 150 F.3d 1140 (9th Cir. 1998): a bank director's use of Gold River Investments' escrow deposits to buy land for Stoddard-Buhler Land Company; convictions and the $30,000 loss affirmed, the $116,223 restitution order remanded over a partial dissent.

Licence: Public-domain court opinion; Caselaw Access Project data CC0

| File | Source document | URL |
|---|---|---|
| stoddard-decision.txt | United States v. Stoddard, 150 F.3d 1140 (9th Cir. 1998-07-30) | https://static.case.law/f3d/150/cases/1140-01.json |

## real4-autoland

NTSB DCA24LA328 — Cirrus SF50 N442CV struck an unidentified object on approach to Austin-Bergstrom (September 14, 2024) and its Emergency Autoland activated unintentionally; final narratives, probable cause and coded fields (the coded departure city is printed as the database has it).

Licence: US Government work (public domain, 17 U.S.C. § 105)

| File | Source document | URL |
|---|---|---|
| autoland-report-page-1.txt | NTSB DCA24LA328 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20241017195334); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24LA328) |
| autoland-factual.txt | NTSB DCA24LA328 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20241017195334); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24LA328) |
| autoland-analysis.txt | NTSB DCA24LA328 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20241017195334); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24LA328) |
| autoland-probable-cause.txt | NTSB DCA24LA328 narratives and coded fields | https://data.ntsb.gov/avdata (up01NOV.mdb: events, aircraft, narratives for ev_id 20241017195334); report: https://data.ntsb.gov/carol-main-public/basic-search (NTSB number DCA24LA328) |
