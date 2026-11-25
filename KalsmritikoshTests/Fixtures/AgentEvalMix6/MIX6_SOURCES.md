# Agent eval fair run 6 — six new public cases from new domains and countries (sources and licences)

Added 2026-11-25 for the AI-50 fair run 6 (`AgentReaderEvalTests`, `.fair6` layout; owner: "it should work for any case"). Solved (or, for the Glencore employees, charged and listed for trial) public matters from domains and countries the eval had not used: US health-care fraud, a UK insurance ("crash for cash") fraud, a business email compromise, a Canadian procurement bid-rigging case, a New Zealand Serious Fraud Office case, and a UK bribery case with US dollars and pounds in the same documents. None of their names occurs anywhere else in the repository. Each case folder holds only the documents the app imports (this file sits outside the case folders on purpose, and its name is unique because the test bundle flattens resources). Text is the publisher's own, HTML stripped, list items written as "- " lines. Fetched 2026-11-25:

- DOJ releases from the justice.gov press-release API (`https://www.justice.gov/api/v1/press_releases.json?parameters[title]=…`, field `body`), with the title and a line naming the office, the release number and the date added on top.
- gov.uk pages from the GOV.UK Content API (`https://www.gov.uk/api/content/<path>`, `details.body`), with the title, the issuing body and the first-published date (case pages: last-updated date) added on top, followed by the page's own summary line.
- CPS, Competition Bureau and NZ SFO pages from the page's main content (`<main>`), with the title and the body / date line added on top; page furniture dropped (navigation, "Back to CPS News centre", the "Contacts" block and everything after it on canada.ca, "About the SFO", "(external link)" markers, the case study's "Download the PDF" section and the questions after it). Two words that an inline tag split across paragraphs on the NZ pages ("“We / would", "Act 2009 / .") are re-joined.
- The CPS 2019 release now returns 403 to scripted requests; its text is the Internet Archive copy (`https://web.archive.org/web/2024id_/<url>`) of the CPS page. canada.ca does not answer scripted requests from this machine; the two Competition Bureau releases are the Internet Archive copies (`https://web.archive.org/web/2026id_/<url>`) of the canada.ca pages.

Questions live in `KalsmritikoshTests/AgentReaderEvalTests.swift`; answer keys are kept outside the repository.

## mix6-midway (health-care fraud, US)

U.S. Department of Justice (Criminal Division, Medicare Fraud Strike Force) — Midway Medical Center Inc., a Miami HIV infusion clinic: $10 million Medicare fraud by physicians Carmen Lourdes del Cueto, Roberto Rodriguez and Carlos Garrido, medical assistants Gonzalo Nodarse and Alexis Carrazana and chemist Alexis Dagnesses. Indictment, pleas and two sentencing releases (2009).

Licence: US Government work (public domain, 17 U.S.C. § 105).

| File | Source document | URL |
|---|---|---|
| midway-2009-02-13-doj-press-release-09-122.txt | Three Miami Physicians and Three Medical Workers Charged with $10 Million Medicare Fraud Scheme (09-122) | https://www.justice.gov/archives/opa/pr/three-miami-physicians-and-three-medical-workers-charged-10-million-medicare-fraud-scheme |
| midway-2009-03-23-doj-press-release-09-261.txt | Two Doctors and Two Medical Assistants Plead Guilty in $10 Million Medicare Fraud Scheme (09-261) | https://www.justice.gov/archives/opa/pr/two-doctors-and-two-medical-assistants-plead-guilty-10-million-medicare-fraud-scheme |
| midway-2009-06-05-doj-press-release-09-557.txt | Four Miami-Area Residents Sentenced in $10 Million Medicare Fraud Scheme (09-557) | https://www.justice.gov/archives/opa/pr/four-miami-area-residents-sentenced-10-million-medicare-fraud-scheme |
| midway-2009-06-29-doj-press-release-09-637.txt | Miami Physician Sentenced to 97 Months in Prison for Role in $10 Million Medicare Fraud Scheme (09-637) | https://www.justice.gov/archives/opa/pr/miami-physician-sentenced-97-months-prison-role-10-million-medicare-fraud-scheme |

## mix6-crash (insurance fraud, UK)

Crown Prosecution Service — a staged "crash for cash" collision with a Tesco delivery van on 11 March 2016: Metropolitan Police officers Hardeep Dehal (convicted 2019) and Kuldip Singh (extradited from Georgia, sentenced 2026), with Raiyaan Anwar, Krishna Ghanaseelan / Gnanaseelan (spelt both ways, as published) and Alper Emin.

Licence: Open Government Licence v3.0 (CPS "Crown Copyright and Disclaimer", https://www.cps.gov.uk/crown-copyright-and-disclaimer, checked 2026-11-25: "You may use and re-use the information featured on this website (not including logos) free of charge in any format or medium, under the terms of the Open Government Licence v3.0"). Attribution: "Contains public sector information licensed under the Open Government Licence v3.0."

| File | Source document | URL |
|---|---|---|
| crash-2019-07-24-cps-press-release.txt | Police officer found guilty of £18,000 crash-for-cash fraud (CPS, 24 July 2019) | https://www.cps.gov.uk/cps-london-north-london-south/news/police-officer-found-guilty-ps18000-crash-cash-fraud (text from https://web.archive.org/web/2024id_/https://www.cps.gov.uk/cps-london-north-london-south/news/police-officer-found-guilty-ps18000-crash-cash-fraud) |
| crash-2026-09-18-cps-press-release.txt | UPDATED WITH SENTENCE: Former police officer jailed for involvement in fraudulent ‘crash for cash’ scam (CPS, 18 September 2026) | https://www.cps.gov.uk/national-news/news/updated-sentence-former-police-officer-jailed-involvement-fraudulent-crash-cash |

## mix6-bec (cyber / business email compromise, US)

U.S. Attorney's Office, Southern District of New York — Evaldas Rimasauskas of Vilnius, Lithuania: a Latvian company named like an Asian computer hardware maker, bank accounts in Latvia and Cyprus, over $100 million (later: over $120 million) wired by two U.S. Internet companies. Extradition (2017), plea (March 2019) and sentence (December 2019).

Licence: US Government work (public domain, 17 U.S.C. § 105).

| File | Source document | URL |
|---|---|---|
| rimasauskas-2017-08-17-doj-press-release-17-263.txt | Lithuanian Man Extradited For Theft Of Over $100 Million In Fraudulent Business Email Compromise Scheme Against Multinational Internet Companies (17-263) | https://www.justice.gov/usao-sdny/pr/lithuanian-man-extradited-theft-over-100-million-fraudulent-business-email-compromise |
| rimasauskas-2019-03-20-doj-press-release-19-087.txt | Lithuanian Man Pleads Guilty To Wire Fraud For Theft Of Over $100 Million In Fraudulent Business Email Compromise Scheme (19-087) | https://www.justice.gov/usao-sdny/pr/lithuanian-man-pleads-guilty-wire-fraud-theft-over-100-million-fraudulent-business |
| rimasauskas-2019-12-19-doj-press-release-19-441.txt | Lithuanian Man Sentenced To 5 Years In Prison For Theft Of Over $120 Million In Fraudulent Business Email Compromise Scheme (19-441) | https://www.justice.gov/usao-sdny/pr/lithuanian-man-sentenced-5-years-prison-theft-over-120-million-fraudulent-business |

## mix6-brandon (procurement fraud, Canada)

Competition Bureau Canada — five contractors in Brandon, Manitoba (Geoff Gregoire, Guy Pringle, James Kauk, Ryan Lamont, Doug Gunnarson) who divided up Manitoba Housing and Renewal Corporation social housing refurbishment contracts (2011–2016): charges (December 2022) and guilty pleas with fines (February 2025).

Licence — NOT the Open Government Licence – Canada. Checked 2026-11-25: canada.ca pages are published under the Canada.ca "Terms and conditions" (https://www.canada.ca/en/transparency/terms.html), which permit reproduction "in whole or in part for non-commercial purposes, and in any format, without charge or further permission", provided the reproducer exercises due diligence on accuracy, indicates the complete title and the author, and indicates that the reproduction is a copy of the version available at the original URL; commercial redistribution needs written permission. The OGL – Canada covers datasets on open.canada.ca, not these news pages. These two files are used only as test inputs in this repository (not shipped in the app). Attribution: "Competition Bureau Canada, news releases ‘Contractors in Brandon, Manitoba, charged with conspiracy related to social housing projects’ (December 19, 2022) and ‘Five contractors in Brandon, Manitoba, plead guilty to conspiracy related to social housing projects’ (February 6, 2025). This reproduction is a copy of the versions available at the URLs below."

| File | Source document | URL |
|---|---|---|
| brandon-2022-12-19-competition-bureau-news-release.txt | Contractors in Brandon, Manitoba, charged with conspiracy related to social housing projects (Competition Bureau Canada, December 19, 2022) | https://www.canada.ca/en/competition-bureau/news/2022/12/contractors-in-brandon-manitoba-charged-with-conspiracy-related-to-social-housing-projects.html |
| brandon-2025-02-06-competition-bureau-news-release.txt | Five contractors in Brandon, Manitoba, plead guilty to conspiracy related to social housing projects (Competition Bureau Canada, February 6, 2025) | https://www.canada.ca/en/competition-bureau/news/2025/02/five-contractors-in-brandon-manitoba-plead-guilty-to-conspiracy-related-to-social-housing-projects.html |

## mix6-sharma (New Zealand)

Serious Fraud Office (New Zealand) — Neha Sharma (née Chandrasekaran), former Oranga Tamariki Property and Facilities Manager, and her husband Amandeep Sharma (Divine Connection): about $2.1 million obtained by deception, just under $800,000 laundered to India, forged references (Oranga Tamariki, Waka Kotahi NZ Transport Agency). Charges (2023), pleas and sentences (2025), the case page (case 221236, closed) and the SFO's counter-fraud case study of the matter.

Licence: Creative Commons Attribution 4.0 International (CC BY 4.0) — SFO copyright page (https://www.sfo.govt.nz/copyright, checked 2026-11-25): "this copyright material is licensed for re-use under the Creative Commons Attribution 4.0 International Licence … you are free to copy, distribute and adapt the material, as long as you attribute it to the Serious Fraud Office" (logos, design and imagery excluded; none used). Attribution: "© Serious Fraud Office (New Zealand), licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Text only; page furniture removed as described above."

| File | Source document | URL |
|---|---|---|
| sharma-2023-06-14-sfo-media-release.txt | SFO files charges against former Oranga Tamariki employee over $2 million fraud (14 June 2023) | https://www.sfo.govt.nz/media-cases/media-releases/sfo-files-charges-against-former-oranga-tamariki-employee-over-2-million-fraud |
| sharma-2025-05-16-sfo-media-release.txt | Husband and wife admit $2 million fraud against Oranga Tamariki in SFO case (16 May 2025) | https://www.sfo.govt.nz/media-cases/media-releases/husband-and-wife-admit-2-million-fraud-against-oranga-tamariki-in-sfo-case |
| sharma-2025-06-19-sfo-media-release.txt | Husband who worked with public servant wife to defraud Oranga Tamariki of $2 million sentenced in SFO case (19 June 2025) | https://www.sfo.govt.nz/media-cases/media-releases/husband-who-worked-with-public-servant-wife-to-defraud-oranga-tamariki-of-2-million-sentenced-in-sfo-case |
| sharma-sfo-case-page.txt | Neha Sharma and Amandeep Sharma — SFO case page (case number 221236) | https://www.sfo.govt.nz/media-cases/cases/neha-sharma-and-amandeep-sharma |
| sharma-sfo-counter-fraud-case-study.txt | Husband and wife work together to defraud Oranga Tamariki of over $2 million — counter-fraud case study | https://www.sfo.govt.nz/counter-fraud/case-studies/husband-and-wife-work-together-to-defraud-oranga-tamariki-of-over-2-million |

## mix6-glencore (second currency: US dollars and pounds)

Serious Fraud Office (UK) — Glencore Energy (UK) Ltd: seven counts of bribery (bribes "worth over $25 million"), guilty pleas on 21 June 2022 and a £280 million penalty and confiscation; six former employees charged in 2024 over oil contracts in Cameroon, Nigeria and the Ivory Coast (trial listed for 4 October 2027). Two case pages and two press releases.

Licence: Open Government Licence v3.0 (https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/). Attribution: "Contains public sector information licensed under the Open Government Licence v3.0."

| File | Source document | URL |
|---|---|---|
| glencore-2024-08-01-sfo-press-release.txt | SFO charges five former Glencore employees (SFO, 1 August 2024) | https://www.gov.uk/government/news/sfo-charges-five-former-glencore-employees |
| glencore-2024-09-10-sfo-press-release.txt | Former Glencore employees in court charged with bribery offences (SFO, 10 September 2024) | https://www.gov.uk/government/news/former-glencore-employees-in-court-charged-with-bribery-offences |
| glencore-sfo-case-page-employees.txt | Glencore employees — SFO case page (last updated 10 November 2025) | https://www.gov.uk/sfo-cases/glencore-employees |
| glencore-sfo-case-page-group.txt | Glencore group of companies — SFO case page (last updated 29 November 2024) | https://www.gov.uk/sfo-cases/glencore-group-of-companies |
