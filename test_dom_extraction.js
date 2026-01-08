#!/usr/bin/env node

const fs = require('fs');
const { JSDOM } = require('jsdom');

// Read the HTML file that contains the bracket data
const htmlFilePath = '/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_debug_2025-08-31_14-33-46_after_interactions.html';

console.log('🔍 Testing DOM Extraction Logic');
console.log('📁 Reading HTML file:', htmlFilePath);

try {
    const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');
    console.log('📊 HTML file size:', htmlContent.length, 'characters');
    
    // Create a DOM from the HTML content
    const dom = new JSDOM(htmlContent);
    const document = dom.window.document;
    
    console.log('\n🎯 Starting DOM extraction test...\n');
    
    // This is the exact same JavaScript logic from our DOMExtractor.swift
    const extractScript = function() {
        try {
            console.log('🔍 Starting comprehensive bracket extraction...');
            
            // Find all match containers using multiple selection strategies
            let matchCards = document.querySelectorAll('.match-card.match, [id^="match"]');
            
            // If we don't find enough, try broader selectors
            if (matchCards.length < 10) {
                console.log('🔄 Only found', matchCards.length, 'matches, trying broader selectors...');
                
                // Try alternative selectors (avoid :has() pseudo-class - not fully supported in WebKit)
                const alternativeSelectors = [
                    '[class*="match-card"]',
                    '[class*="bracket-match"]', 
                    '.v-card .bracket-team',
                    '[id*="match"]',
                    '.bracket .match',
                    '.round .match',
                    '.match',
                    '[data-match-id]'
                ];
                
                for (let selector of alternativeSelectors) {
                    try {
                        const altCards = document.querySelectorAll(selector);
                        if (altCards.length > matchCards.length) {
                            console.log('✅ Found', altCards.length, 'matches with selector:', selector);
                            matchCards = altCards;
                            break;
                        }
                    } catch (error) {
                        console.log('❌ Selector failed:', selector, error.message);
                    }
                }
            }
            
            console.log('🎲 Total match cards found:', matchCards.length);
            
            const results = [];
            
            // Process each match card
            for (let i = 0; i < matchCards.length; i++) {
                const matchCard = matchCards[i];
                
                const matchData = {
                    matchNumber: '',
                    time: '',
                    court: '',
                    homeTeam: '',
                    awayTeam: '',
                    homeSeed: '',
                    awaySeed: '',
                    isWaiting: false
                };
                
                // Extract match number
                const matchNumberElement = matchCard.querySelector('.match-number, [class*="match-number"], .match-title');
                if (matchNumberElement) {
                    matchData.matchNumber = matchNumberElement.textContent.trim();
                }
                
                // Extract time
                const timeElement = matchCard.querySelector('.time, .match-time, [class*="time"]');
                if (timeElement) {
                    matchData.time = timeElement.textContent.trim();
                }
                
                // Extract court
                const courtElement = matchCard.querySelector('.court, .match-court, [class*="court"]');
                if (courtElement) {
                    matchData.court = courtElement.textContent.trim();
                }
                
                // Find team elements
                const teamElements = matchCard.querySelectorAll('.team, .bracket-team, [class*="team"]');
                
                for (let j = 0; j < teamElements.length; j++) {
                    const teamElement = teamElements[j];
                    const isHome = teamElement.classList.contains('home');
                    const isAway = teamElement.classList.contains('away');
                    
                    // Extract seed
                    const seedElement = teamElement.querySelector('.seed');
                    const seed = seedElement ? seedElement.textContent.trim() : '';
                    
                    // Extract team name - try multiple selectors
                    let teamName = '';
                    let isWaiting = false;
                    
                    // Try multiple selectors for team names
                    const teamSelectors = ['.team', '.team-name', '.bracket-team', '[class*="team"]'];
                    let teamNameElement = null;
                    
                    for (let selector of teamSelectors) {
                        teamNameElement = teamElement.querySelector(selector);
                        if (teamNameElement) break;
                    }
                    
                    if (teamNameElement) {
                        // Get raw text content
                        let rawText = teamNameElement.textContent || teamNameElement.innerText || '';
                        
                        // Clean up the text - remove HTML comments and extra whitespace
                        teamName = rawText
                            .replace(/<!--.*?-->/g, '')  // Remove HTML comments
                            .replace(/\s+/g, ' ')        // Normalize whitespace
                            .trim();
                        
                        console.log(`🏐 Raw team text: "${rawText}" -> Cleaned: "${teamName}"`);
                        
                        // Check if it's a "Winner" placeholder
                        isWaiting = teamName.includes('Winner') || teamName.includes('Bye') || 
                                   teamNameElement.classList.contains('waiting') ||
                                   teamName === '' || teamName === '-';
                        
                        if (isWaiting) {
                            matchData.isWaiting = true;
                            teamName = teamName || 'TBD';
                        }
                    } else {
                        // If no team element found, try getting text directly from parent
                        const parentText = teamElement.textContent || teamElement.innerText || '';
                        teamName = parentText.replace(/<!--.*?-->/g, '').replace(/\s+/g, ' ').trim();
                        console.log(`🏐 No team element found, using parent text: "${teamName}"`);
                        
                        if (!teamName || teamName.length < 2) {
                            teamName = 'Unknown Team';
                            isWaiting = true;
                        }
                    }
                    
                    if (isHome) {
                        matchData.homeTeam = teamName;
                        matchData.homeSeed = seed;
                    } else if (isAway) {
                        matchData.awayTeam = teamName;
                        matchData.awaySeed = seed;
                    }
                }
                
                // Debug: Show what we extracted for each match card
                console.log(`🔍 Match card ${i + 1} (${matchCard.id || 'no-id'}):`, {
                    matchNumber: matchData.matchNumber,
                    time: matchData.time,
                    court: matchData.court,
                    homeTeam: matchData.homeTeam,
                    awayTeam: matchData.awayTeam,
                    isWaiting: matchData.isWaiting
                });
                
                // Only include matches that have essential data
                if (matchData.matchNumber && (matchData.court || matchData.time)) {
                    results.push(matchData);
                    console.log('✅ INCLUDED:', matchData.matchNumber, '-', matchData.homeTeam, 'vs', matchData.awayTeam, '- Court:', matchData.court, 'at', matchData.time);
                } else {
                    console.log('❌ EXCLUDED: Missing essential data');
                }
            }
            
            console.log('🎯 Extracted', results.length, 'valid matches');
            return results;
            
        } catch (error) {
            console.error('❌ JavaScript extraction error:', error);
            console.error('Error details:', error.message, error.stack);
            return []; // Return empty array instead of failing
        }
    };
    
    // Execute the extraction function
    const results = extractScript();
    
    console.log('\n📋 FINAL RESULTS:');
    console.log('Total matches extracted:', results.length);
    
    results.forEach((match, index) => {
        console.log(`\n${index + 1}. Match ${match.matchNumber}`);
        console.log(`   Teams: ${match.homeTeam} vs ${match.awayTeam}`);
        console.log(`   Court: ${match.court}`);
        console.log(`   Time: ${match.time}`);
        console.log(`   Waiting: ${match.isWaiting}`);
    });
    
    if (results.length === 0) {
        console.log('\n🔍 Let\'s debug what\'s in the HTML...');
        
        // Check for team names we know should be there
        const targetTeams = ['Connole', 'Roschitz', 'Curtis', 'Piangerelli', 'Dailey', 'Mota'];
        const bodyText = document.body.textContent || '';
        
        console.log('\nSearching for known team names in HTML:');
        targetTeams.forEach(team => {
            const found = bodyText.includes(team);
            console.log(`  ${team}: ${found ? '✅ FOUND' : '❌ NOT FOUND'}`);
        });
        
        // Check what match-related elements exist
        console.log('\nChecking for various match elements:');
        const elementChecks = [
            '.match-card',
            '.match',
            '[class*="match"]',
            '.bracket-team',
            '.team',
            '[class*="team"]',
            '.court',
            '.time'
        ];
        
        elementChecks.forEach(selector => {
            try {
                const elements = document.querySelectorAll(selector);
                console.log(`  ${selector}: ${elements.length} elements found`);
                if (elements.length > 0 && elements.length < 10) {
                    // Show a few examples
                    for (let i = 0; i < Math.min(3, elements.length); i++) {
                        const text = elements[i].textContent.trim().substring(0, 50);
                        console.log(`    Example ${i + 1}: "${text}"`);
                    }
                }
            } catch (error) {
                console.log(`  ${selector}: ERROR - ${error.message}`);
            }
        });
    }

} catch (error) {
    console.error('❌ Error reading HTML file:', error.message);
    console.log('\n📁 Please check that the file exists at:');
    console.log(htmlFilePath);
    
    // Try to list available files
    const dir = '/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents';
    try {
        const files = fs.readdirSync(dir);
        const vblFiles = files.filter(f => f.includes('vbl_debug') && f.includes('after_interactions'));
        console.log('\n📋 Available VBL debug files:');
        vblFiles.forEach(file => console.log(`  ${file}`));
    } catch (dirError) {
        console.log('Could not list directory:', dirError.message);
    }
}