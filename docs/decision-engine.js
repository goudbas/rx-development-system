// RX Development System — Daily Decision Engine (Deel 6/10 uit het ontwerpdocument).
// Pure logica: geen DOM, geen Supabase. Componenten (skills/strength/mobility incl. hun oefeningen
// en spiergroep-conflicten) komen als data binnen vanuit Supabase (zie index.html loadSkills()) —
// deze module bevat alleen de beslisregels, geen hardcoded content meer.

(function (global) {

  // Spiergroepen die je kunt selecteren als (veel) spierpijn. Vaste UI-enum, geen groeiende
  // contentbibliotheek — blijft daarom hardcoded (in tegenstelling tot de componenten zelf).
  const MUSCLE_GROUPS = [
    { id: 'schouders', label: 'Schouders' },
    { id: 'rug', label: 'Rug' },
    { id: 'borst', label: 'Borst' },
    { id: 'armen', label: 'Armen/grip' },
    { id: 'benen', label: 'Benen' },
    { id: 'kuiten', label: 'Kuiten' },
    { id: 'core', label: 'Core' }
  ];

  function timingOf(component, componentsByName) {
    return componentsByName[component]?.timing || 'any';
  }

  // Readiness-classificatie (Deel 6, coaching judgement [C]): één slechte waarde triggert nooit
  // alleen RED, behalve significante pijn — dat blijft een harde stop.
  function classifyReadiness(logToday) {
    if (logToday?.pain_level === 'significant') return 'red';
    const readiness = logToday?.readiness;
    const fatigue = logToday?.fatigue;
    if (readiness != null && readiness <= 2 && fatigue != null && fatigue >= 4) return 'red';
    if (
      logToday?.pain_level === 'mild' ||
      readiness === 3 ||
      (fatigue != null && fatigue >= 4) ||
      (logToday?.soreness != null && logToday.soreness >= 4) ||
      (logToday?.sleep != null && logToday.sleep <= 2)
    ) return 'amber';
    return 'green';
  }

  function painReasoning(logToday) {
    if (logToday?.pain_level !== 'significant') return null;
    return `Significante pijn gemeld${logToday.pain_location ? ` (${logToday.pain_location})` : ''} — geen extra belastend werk vandaag.`;
  }

  // Deelt de kandidaten in drie groepen o.b.v. gemelde spiergroep-spierpijn: genegeerd (block),
  // gedowngraded (blijft kandidaat, maar alleen gekozen als er geen normale optie is), normaal.
  function classifyConflicts(candidates, soreMuscleGroups, componentsByName) {
    const normal = [], downgraded = [], notes = [];
    (candidates || []).forEach(t => {
      const conflicts = componentsByName[t.component]?.conflicts || {};
      let severity = null;
      (soreMuscleGroups || []).forEach(g => {
        if (conflicts[g] && (!severity || (severity === 'downgrade' && conflicts[g] === 'block'))) severity = conflicts[g];
      });
      if (severity === 'block') {
        notes.push(`${t.component} geblokkeerd: ${soreMuscleGroups.filter(g => conflicts[g] === 'block').join(', ')} sore.`);
      } else if (severity === 'downgrade') {
        downgraded.push(t);
        notes.push(`${t.component} gedowngraded: ${soreMuscleGroups.filter(g => conflicts[g] === 'downgrade').join(', ')} sore — alleen bij gebrek aan alternatief.`);
      } else {
        normal.push(t);
      }
    });
    return { normal, downgraded, notes };
  }

  function pickUnderTarget(candidates) {
    const under = candidates
      .filter(t => t.actual_count < t.target_min)
      .sort((a, b) => (a.actual_count / Math.max(a.target_min, 1)) - (b.actual_count / Math.max(b.target_min, 1)));
    return under[0] || null;
  }

  function selectCandidate(weeklyTargets, componentsByName, soreMuscleGroups, timingExclude, excludeNames, frozenNames) {
    let candidates = (weeklyTargets || [])
      .filter(t => timingOf(t.component, componentsByName) !== timingExclude)
      .filter(t => !(excludeNames || []).includes(t.component));

    const notes = [];
    const frozen = frozenNames || [];
    candidates = candidates.filter(t => {
      if (frozen.includes(t.component)) {
        notes.push(`${t.component} is bevroren (safety freeze) — uitgesloten van aanbevelingen tot ontdooid.`);
        return false;
      }
      return true;
    });

    const { normal, downgraded, notes: conflictNotes } = classifyConflicts(candidates, soreMuscleGroups, componentsByName);
    notes.push(...conflictNotes);

    let pick = pickUnderTarget(normal);
    let downgradedNote = null;
    if (!pick) {
      pick = pickUnderTarget(downgraded);
      if (pick) downgradedNote = `Let op: ${pick.component} is gedowngraded vanwege gemelde spierpijn — hou volume/intensiteit bewust laag.`;
    }
    return { pick, notes, downgradedNote };
  }

  function componentsToMap(components) {
    const map = {};
    (components || []).forEach(c => { map[c.name] = c; });
    return map;
  }

  // ---------- Voor de class: skill/mobility-advies o.b.v. weekly targets + spierpijn, NIET o.b.v. vandaag se class (die is nog onbekend). ----------
  function computePreClassRecommendation({ logToday, weeklyTargets, components, frozenNames }) {
    const tier = classifyReadiness(logToday);
    const componentsByName = componentsToMap(components);

    if (tier === 'red') {
      return { tier, recovery: true, reasoning: painReasoning(logToday) || 'Readiness te laag — vandaag geen belastend werk vóór de class.', notes: [] };
    }

    const excludeNames = tier === 'amber' ? ['Strength'] : [];
    const { pick, notes, downgradedNote } = selectCandidate(weeklyTargets, componentsByName, logToday?.sore_muscle_groups, 'post', excludeNames, frozenNames);
    if (tier === 'amber') notes.push('Strength uitgesloten: readiness AMBER.');

    if (!pick) {
      return { tier, recovery: true, reasoning: 'Geen openstaande skill/mobility-targets deze week (of alles geblokkeerd door spierpijn).', notes };
    }
    return {
      tier, component: pick.component,
      reasoning: [
        `Meest onderbelicht deze week (${pick.actual_count}/${pick.target_min}-${pick.target_max}), vóór de class.`,
        downgradedNote
      ].filter(Boolean).join(' '),
      notes
    };
  }

  // ---------- Na de class: strength/mobility-advies, houdt nu wél rekening met de zojuist gelogde class load. ----------
  function computePostClassRecommendation({ logToday, classLoadToday, weeklyTargets, components, frozenNames }) {
    let tier = classifyReadiness(logToday);
    const componentsByName = componentsToMap(components);

    if (tier === 'red') {
      return { tier, recovery: true, reasoning: painReasoning(logToday) || 'Readiness te laag — vandaag geen belastend werk na de class.', notes: [] };
    }

    const cl = classLoadToday;
    if (cl?.overall_load === 'very_hard' && tier === 'green') tier = 'amber';

    // Sinds de na-de-class-invoer vereenvoudigd is naar RPE + workout-type (geen losse
    // overhead/pulling-chips meer), is dit een grovere proxy voor "vandaag zwaar op de
    // bovenbouw belast" — coaching judgement [C], bewust simpeler in ruil voor minder invoer.
    const shoulderLoadedToday = cl && (cl.workout_type === 'strength' || cl.workout_type === 'mixed') && (cl.rpe ?? 0) >= 7;
    const mildPainShoulder = logToday?.pain_level === 'mild' && (logToday.pain_location || '').toLowerCase().includes('schouder');
    if (mildPainShoulder && shoulderLoadedToday) {
      return {
        tier, component: 'Mobility',
        reasoning: 'Milde schouderklacht + zware kracht/mixed-training vandaag → alleen schouder-stability.',
        notes: []
      };
    }

    const excludeNames = tier === 'amber' ? ['Strength'] : [];
    const { pick, notes, downgradedNote } = selectCandidate(weeklyTargets, componentsByName, logToday?.sore_muscle_groups, 'pre', excludeNames, frozenNames);
    if (tier === 'amber' && excludeNames.includes('Strength')) {
      notes.push(cl?.overall_load === 'very_hard' ? 'Strength uitgesloten: zware class vandaag.' : 'Strength uitgesloten: readiness AMBER.');
    }

    if (!pick) {
      return { tier, recovery: true, reasoning: 'Geen openstaande post-class targets vandaag — rust of onderhoud volstaat.', notes };
    }
    return {
      tier, component: pick.component,
      reasoning: [
        `Meest onderbelicht deze week (${pick.actual_count}/${pick.target_min}-${pick.target_max}).${cl ? ` Class load vandaag: overhead ${cl.overhead || '-'}, pulling ${cl.pulling || '-'}, overall ${cl.overall_load || '-'}.` : ''}`,
        downgradedNote
      ].filter(Boolean).join(' '),
      notes
    };
  }

  // Niveau-upgrade (coach-feedback): minimaal `level.pass_sessions_min` kwalificerende sessies
  // (quality_score >= pass_quality_min) op dit niveau, waarvan minstens 1x Training A én 1x Training B —
  // niet per se opeenvolgend, want A/B-afwisseling zou "consecutive" onnodig breken.
  function evaluateLevelUp({ recentSessions, level }) {
    if (!level || !level.pass_sessions_min) return false;
    const qualityMin = level.pass_quality_min ?? 4;
    const qualifying = (recentSessions || []).filter(s => (s.quality_score ?? 0) >= qualityMin);
    if (qualifying.length < level.pass_sessions_min) return false;
    const hasA = qualifying.some(s => s.variant === 'a');
    const hasB = qualifying.some(s => s.variant === 'b');
    // Skills zonder variant-data (bv. oude sessies vóór deze migratie) tellen niet mee voor de
    // A/B-dekking, maar blokkeren de upgrade ook niet als er verder geen B-variant bestaat (variant='a' default).
    return hasA && hasB;
  }

  // Kiest welke variant (A/B) het minst gelogd is op dit niveau, zodat het snelle ✓ Gedaan-tikje
  // vanzelf afwisselt zonder een extra keuze-tik te kosten. Bij gelijkstand: A.
  function pickVariant(recentSessions) {
    const countFor = (v) => (recentSessions || []).filter(s => s.variant === v).length;
    return countFor('a') <= countFor('b') ? 'a' : 'b';
  }

  // Automatische veiligheidsbevriezing: alleen wat betrouwbaar uit de sessie-historie af te leiden is.
  // Andere triggers uit de coach-feedback (coach-flag, aanhoudende pijn na 48u) vereisen menselijke
  // inschatting en lopen daarom via een handmatige bevriezen/ontdooien-knop in de UI, niet hier.
  function evaluateSafetyFreeze({ recentSessions, level }) {
    const sessions = recentSessions || [];
    const last = sessions[0];
    if (last && (last.pain_score ?? 0) > 2) {
      return { frozen: true, reason: `Pijnscore ${last.pain_score}/10 gemeld bij de laatste sessie.` };
    }
    const qualityMin = level?.pass_quality_min ?? 4;
    const lastTwo = sessions.slice(0, 2);
    if (lastTwo.length === 2 && lastTwo.every(s => (s.quality_score ?? 0) < qualityMin)) {
      return { frozen: true, reason: 'Twee sessies op rij onder de kwaliteitsdrempel — mogelijke terugval.' };
    }
    return { frozen: false, reason: null };
  }

  function currentWeekNumber(block) {
    const start = new Date(block.start_date);
    const diffDays = Math.floor((new Date() - start) / 86400000);
    return Math.max(1, Math.floor(diffDays / 7) + 1);
  }

  global.DecisionEngine = {
    MUSCLE_GROUPS,
    classifyReadiness,
    computePreClassRecommendation, computePostClassRecommendation, currentWeekNumber,
    evaluateLevelUp, pickVariant, evaluateSafetyFreeze
  };

})(window);
