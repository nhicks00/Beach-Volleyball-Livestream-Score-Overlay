#!/usr/bin/env node

const fs = require('fs');
const { JSDOM } = require('jsdom');

// Read the HTML file 
const htmlFilePath = '/Users/nathanhicks/Library/Containers/com.NathanHicks.MultiCourtScore/Data/Documents/vbl_debug_2025-08-31_14-33-46_after_interactions.html';

console.log('🔍 Inspecting Match Structure in HTML');

try {
    const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');
    const dom = new JSDOM(htmlContent);
    const document = dom.window.document;
    
    // Get the first few match cards to analyze their structure
    const matchCards = document.querySelectorAll('.match');
    
    console.log(`\n📊 Found ${matchCards.length} match cards. Let's inspect the first 3:\n`);
    
    for (let i = 0; i < Math.min(3, matchCards.length); i++) {
        const matchCard = matchCards[i];
        console.log(`=== MATCH CARD ${i + 1} (ID: ${matchCard.id || 'no-id'}) ===`);
        
        // Show the raw HTML structure (first 500 characters)
        const innerHTML = matchCard.innerHTML.substring(0, 800);
        console.log('Raw HTML:\n', innerHTML, '\n...\n');
        
        // Try to find all possible elements that might contain match info
        console.log('🔍 Analyzing child elements:');
        
        // Get all child elements
        const allChildren = matchCard.querySelectorAll('*');
        console.log(`Total child elements: ${allChildren.length}`);
        
        // Look for elements that might contain match numbers, times, courts
        const potentialMatchInfo = [];
        
        allChildren.forEach((element, index) => {
            const text = element.textContent.trim();
            const className = element.className;
            const tagName = element.tagName.toLowerCase();
            
            // Skip if too much text (likely team names)
            if (text.length > 50) return;
            
            // Look for patterns that might be match numbers, times, courts
            const isMatchNumber = /match\s*\d+/i.test(text) || /^\d+$/.test(text);
            const isTime = /\d+:\d+/.test(text) || /\d+\s*(am|pm)/i.test(text);
            const isCourt = /court\s*\d+/i.test(text) || /^\d+$/.test(text);
            
            if (isMatchNumber || isTime || isCourt || text.includes(':')) {
                potentialMatchInfo.push({
                    index,
                    tagName,
                    className,
                    text,
                    isMatchNumber,
                    isTime,
                    isCourt
                });
            }
        });
        
        console.log('\n📋 Potential match info elements:');
        potentialMatchInfo.forEach(info => {
            console.log(`  ${info.tagName}.${info.className}: "${info.text}" (match:${info.isMatchNumber}, time:${info.isTime}, court:${info.isCourt})`);
        });
        
        // Also look for specific patterns in the text content
        const fullText = matchCard.textContent;
        console.log('\n📝 Full text content analysis:');
        
        // Look for time patterns
        const timeMatches = fullText.match(/\d{1,2}:\d{2}\s*(AM|PM)?/gi) || [];
        console.log(`Time patterns found: ${timeMatches.join(', ')}`);
        
        // Look for court patterns  
        const courtMatches = fullText.match(/court\s*\d+/gi) || [];
        console.log(`Court patterns found: ${courtMatches.join(', ')}`);
        
        // Look for match number patterns
        const matchMatches = fullText.match(/match\s*\d+/gi) || [];
        console.log(`Match number patterns found: ${matchMatches.join(', ')}`);
        
        console.log('\n' + '='.repeat(60) + '\n');
    }
    
    // Now let's see what elements have class names containing time, court, match
    console.log('🔍 Searching for elements with relevant class names:');
    
    const relevantSelectors = [
        '[class*="time"]',
        '[class*="court"]', 
        '[class*="match"]',
        '[class*="number"]',
        '[class*="schedule"]',
        '[class*="venue"]'
    ];
    
    relevantSelectors.forEach(selector => {
        try {
            const elements = document.querySelectorAll(selector);
            console.log(`\n${selector}: ${elements.length} elements`);
            
            // Show first few examples
            for (let i = 0; i < Math.min(5, elements.length); i++) {
                const element = elements[i];
                const text = element.textContent.trim().substring(0, 50);
                console.log(`  ${i + 1}. ${element.tagName.toLowerCase()}.${element.className}: "${text}"`);
            }
        } catch (error) {
            console.log(`${selector}: ERROR - ${error.message}`);
        }
    });

} catch (error) {
    console.error('❌ Error:', error.message);
}