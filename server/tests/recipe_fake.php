<?php
// Shared recipe persistence for the existing no-extension fake SQL suites.
function fakeRecipeQuery(string $sql,array $params): array {
    $recipes=&$GLOBALS['recipes'];$recipes ??= [];
    if (str_starts_with($sql,'INSERT INTO')) {
        [$id,$settings,$key]=$params;
        $recipes[$id]=['generation_id'=>$id,'settings_json'=>$settings,'input_key'=>$key,'resolved_seed'=>null,'created_at'=>gmdate('Y-m-d H:i:s')];
    } elseif (str_starts_with($sql,'UPDATE') && str_contains($sql,'resolved_seed=')) {
        if (isset($recipes[$params[1]])) $recipes[$params[1]]['resolved_seed']=$params[0];
    } elseif (str_starts_with($sql,'UPDATE')) { $recipes[$params[0]]['input_key']=null;
    } elseif (str_contains($sql,'WHERE generation_id=')) { return isset($recipes[$params[0]]) ? [$recipes[$params[0]]]:[];
    } elseif (str_contains($sql,'WHERE input_key=?')) { return array_values(array_filter($recipes,fn($r)=>$r['input_key']===$params[0]));
    } elseif (str_contains($sql,'created_at<=')) { return array_values(array_filter($recipes,fn($r)=>$r['input_key'] && strtotime($r['created_at'].' UTC')<=time()-43200));
    } else { throw new RuntimeException('Unexpected recipe SQL: '.$sql); }
    return [];
}
