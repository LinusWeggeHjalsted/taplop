using UnityEngine;
using System.Collections.Generic;
using System.Linq;

public class FlashStrikeScript : MonoBehaviour, Skill
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private Sprite skillSprite;
    private int cooldown;
    private int currentCooldown = 0;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;

    public string GetSkillName()
    {
        return skillName;
    }

    public string GetSkillType()
    {
        return skillType;
    }

    public string GetDescription()
    {
        return description;
    }

    public float GetRange()
    {
        return range;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public int CurrentCooldown()
    {
        return currentCooldown;
    }

    public void ReduceCooldown(int number)
    {
        currentCooldown -= number;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        if (currentCooldown > 0)
        {
            return -1;
        }
        else
        {
            return 2;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -range; i <= range; i++)
        {
            for (float j = -range; j <= range; j++)
            {
                Vector3 delta = new Vector3(i, j, 0);
                deltas.Add(delta);
            }
        }
        List<Vector3> targetPositions = new List<Vector3>();
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            if (!tileLookup.ContainsKey(targetPosition))
            {
                continue;
            }
            else
            {
                GameObject targetTile = tileLookup[targetPosition];
                TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                if (targetTileScript.IsHighlighted)
                {
                    targetPositions.Add(targetPosition);
                }
            }
        }
        // sort targetPositions by distance to player
        targetPositions = targetPositions.OrderBy(pos => traversableTilesScript.Distance(pos, player.transform.position)).ToList();
        return targetPositions[0];
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.MoveTo(targetPosition);
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
            Vector3 attackTarget = targetPosition + delta;
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            GameObject target = null;
            if (targetPosition == player.transform.position)
            {
                if (enemyLookup.ContainsKey(attackTarget))
                {
                    target = enemyLookup[attackTarget];
                }
            }
            if (enemyLookup.ContainsKey(targetPosition))
            {
                if (attackTarget == player.transform.position)
                {
                    target = player;
                }
            }
            if (target != null)
            {
                EntityScript targetScript = target.GetComponent<EntityScript>();
                targetScript.IncomingDamage(wielderScript.offHandDamage, wielder);
            }
        }
        currentCooldown = cooldown;
        if (wielder == player)
        {
            turnLogicScript.hasAttacked = true;
        }
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        List<Vector3> deltas = new List<Vector3>();
        for (float i = -range; i <= range; i++)
        {
            for (float j = -range; j <= range; j++)
            {
                Vector3 delta = new Vector3(i, j, 0);
                deltas.Add(delta);
            }
        }
        List<Vector3> targetPositions = new List<Vector3>();
        foreach (Vector3 delta in deltas)
        {
            Vector3 targetPosition = fromPosition + delta;
            if (tileLookup.ContainsKey(targetPosition))
            {
                GameObject targetTile = tileLookup[targetPosition];
                TileScript targetTileScript = targetTile.GetComponent<TileScript>();
                if (!targetTileScript.isOccupied)
                {
                    targetTileScript.IsHighlighted = true;
                }
            }
        }
    }

    void Start()
    {
        skillName = "Flash Strike";
        skillType = "Off Hand Skill";
        description = "Teleport then attack each target within skill range";
        cooldown = 3;
        range = 2f;
        skillSprite = Resources.Load<Sprite>("Skill Sprites/FlashStrike");
        traversableTiles = GameObject.Find("Traversable Tiles");
        if (traversableTiles != null)
        {
            traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        }
        enemies = GameObject.Find("Enemies");
        if (enemies != null)
        {
            enemiesScript = enemies.GetComponent<EnemiesScript>();
        }
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
    }
}
