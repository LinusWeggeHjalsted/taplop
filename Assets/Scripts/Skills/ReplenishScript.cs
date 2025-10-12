using UnityEngine;
using System.Collections.Generic;
using System.Linq;

public class ReplenishScript : MonoBehaviour, Skill
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
            EntityScript enemyScript = enemy.GetComponent<EntityScript>();
            int currentHealth = enemyScript.CurrentHealth;
            int maxHealth = enemyScript.MaxHealth;
            float healthRatio = (float)currentHealth / (float)maxHealth;
            if (healthRatio < 0.5f)
            {
                return 0;
            }
            else
            {
                return -1;
            }
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
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.CurrentHealth = wielderScript.MaxHealth;
        currentCooldown = cooldown;
    }

    void Start()
    {
        skillName = "Replenish";
        skillType = "Cantrip";
        description = "Heal to full health";
        cooldown = 5;
        range = 0;
        skillSprite = Resources.Load<Sprite>("Skill Sprites/Replenish");
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        player = GameObject.Find("Player");
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
    }
}
