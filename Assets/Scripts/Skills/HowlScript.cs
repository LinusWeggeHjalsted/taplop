using UnityEngine;
using System.Collections.Generic;

public class HowlScript : MonoBehaviour, Skill
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
            return 0;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
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
            Vector3 position = wielder.transform.position + delta;
            if (enemyLookup.ContainsKey(position))
            {
                GameObject enemyInRange = enemyLookup[position];
                EntityScript enemyScript = enemyInRange.GetComponent<EntityScript>();
                enemyScript.IsActive = true;
            }
        }
        currentCooldown = cooldown;
    }

    void Start()
    {
        skillName = "Howl";
        skillType = "Cantrip";
        description = "Aggro each enemy in range";
        cooldown = 10;
        range = 16f;
        skillSprite = Resources.Load<Sprite>("Skills/Howl");
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
