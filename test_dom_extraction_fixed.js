#!/usr/bin/env node

const fs = require('fs');
const { JSDOM } = require('jsdom');

// Read the HTML file that contains the bracket data
const htmlFilePath = '/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_debug_2025-08-31_14-33-46_after_interactions.html';

console.log('🔍 Testing FIXED DOM Extraction Logic');
console.log('📁 Reading HTML file:', htmlFilePath);

try {
    const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');
    console.log('📊 HTML file size:', htmlContent.length, 'characters');
    
    // Create a DOM from the HTML content
    const dom = new JSDOM(htmlContent);
    const document = dom.window.document;
    
    console.log('\n🎯 Starting FIXED DOM extraction test...\n');
    
    // FIXED extraction logic with correct selectors
    const extractScript = function() {
        try {
            console.log('🔍 Starting comprehensive bracket extraction...');
            
            // Find all match containers - we know .match works
            let matchCards = document.querySelectorAll('.match');
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
                
                // FIXED: Extract match number from .bracket-label .font-weight-bold
                const matchNumberElement = matchCard.querySelector('.bracket-label .font-weight-bold');
                if (matchNumberElement) {
                    matchData.matchNumber = matchNumberElement.textContent.trim();
                }
                
                // FIXED: Extract time and court from .bracket-label spans
                const bracketLabelSpans = matchCard.querySelectorAll('.bracket-label span');
                if (bracketLabelSpans.length >= 2) {
                    // Second span usually contains time
                    const timeText = bracketLabelSpans[1].textContent.trim();
                    if (timeText.match(/\d+:\d+/)) {
                        matchData.time = timeText;
                    }
                }
                
                // Look for court in any span containing "Court:"
                bracketLabelSpans.forEach(span => {
                    const spanText = span.textContent.trim();
                    if (spanText.includes('Court:')) {
                        // Extract number after "Court:"
                        const courtMatch = spanText.match(/Court:\s*(\d+)/);
                        if (courtMatch) {
                            matchData.court = courtMatch[1];
                        }
                    }
                });
                
                // Extract team data (this part was already working)
                const teamElements = matchCard.querySelectorAll('.team, .bracket-team, [class*="team"]');
                
                for (let j = 0; j < teamElements.length; j++) {
                    const teamElement = teamElements[j];
                    const isHome = teamElement.classList.contains('home');
                    const isAway = teamElement.classList.contains('away');
                    
                    // Extract seed
                    const seedElement = teamElement.querySelector('.seed');
                    const seed = seedElement ? seedElement.textContent.trim() : '';
                    
                    // Extract team name
                    let teamName = '';
                    let isWaiting = false;
                    
                    // Get text content from the team element
                    const rawText = teamElement.textContent || teamElement.innerText || '';
                    teamName = rawText
                        .replace(/<!--.*?-->/g, '')  // Remove HTML comments
                        .replace(/\s+/g, ' ')        // Normalize whitespace
                        .trim();
                    
                    // Check if it's a "Winner" placeholder
                    isWaiting = teamName.includes('Winner') || teamName.includes('Bye') || 
                               teamName === '' || teamName === '-';
                    
                    if (isWaiting) {
                        matchData.isWaiting = true;
                        teamName = teamName || 'TBD';
                    }
                    
                    if (isHome) {
                        matchData.homeTeam = teamName;
                        matchData.homeSeed = seed;
                    } else if (isAway) {
                        matchData.awayTeam = teamName;
                        matchData.awaySeed = seed;
                    } else {
                        // If no home/away designation, assign in order
                        if (!matchData.homeTeam && teamName) {
                            matchData.homeTeam = teamName;
                            matchData.homeSeed = seed;
                        } else if (!matchData.awayTeam && teamName) {
                            matchData.awayTeam = teamName;
                            matchData.awaySeed = seed;
                        }
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
                
                // FIXED: More lenient inclusion criteria - include if we have match number OR time OR court
                if (matchData.matchNumber || matchData.time || matchData.court) {
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
            return [];
        }
    };
    
    // Execute the extraction function
    const results = extractScript();
    
    console.log('\n📋 FINAL RESULTS:');
    console.log('Total matches extracted:', results.length);
    console.log('Expected: 17 matches');
    console.log('Success:', results.length === 17 ? '✅' : '❌');
    
    console.log('\n🏐 EXTRACTED MATCHES:');
    results.forEach((match, index) => {
        console.log(`\n${index + 1}. ${match.matchNumber || 'No Match #'}`);
        console.log(`   Teams: ${match.homeTeam} vs ${match.awayTeam}`);
        console.log(`   Court: ${match.court || 'No Court'}`);
        console.log(`   Time: ${match.time || 'No Time'}`);
        console.log(`   Waiting: ${match.isWaiting}`);
    });

} catch (error) {
    console.error('❌ Error reading HTML file:', error.message);
    console.log('Please check that the file exists at:', htmlFilePath);
}