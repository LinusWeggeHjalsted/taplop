using UnityEngine;
using System.Collections.Generic;

public class SliceScript : MonoBehaviour, Skill
{
    public float range = 1f;
    public int cooldown = 0;
    public int currentCooldown = 0;
    public GameObject sword;
    public SwordScript swordScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject damageCalculator;
    public DamageCalculatorScript damageCalculatorScript;
    
    public int GetCurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public void useSkill(Vector3 targetPosition)
    {
        Debug.Log("using slice");
        Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
        GameObject target = null;
        if (enemyLookup.ContainsKey(targetPosition))
        {
            target = enemyLookup[targetPosition];
        }
        if (targetPosition == player.transform.position)
        {
            target = player;
        }
        if (target != null)
        {
            EntityScript targetScript = target.GetComponent<EntityScript>();
            targetScript.IncomingDamage(swordScript.damage);
        }
        // to-do - use actual damage calculation
    }

    public void prepareSkill(Vector3 fromPosition)
    {
        Debug.Log("preparing slice");
        // to-do - clear all highlighting
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -range; i <= range; i++)
        {
            for (float j = -range; j <= range; j++)
            {
                if (i == 0 && j == 0)
                {
                    continue;
                }
                else
                {
                    Vector3 delta = new Vector3(i, j, 0);
                    deltas.Add(delta);
                }
            }
        }
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            if (!tileLookup.ContainsKey(targetPosition))
            {
                continue;
            }
            // to-do - need to implement line of sight check
            GameObject targetTile = tileLookup[targetPosition];
            TileScript targetTileScript = targetTile.GetComponent<TileScript>();
            if (targetTileScript.isOccupied)
            {
                targetTileScript.isHighlighted = true;
            }
        }
        Debug.Log("highlighted possible targets");
    }

    void Start()
    {
        sword = this.transform.parent.gameObject;
        swordScript = sword.GetComponent<SwordScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        damageCalculator = GameObject.Find("Damage Calculator");
        damageCalculatorScript = damageCalculator.GetComponent<DamageCalculatorScript>();
    }
}
