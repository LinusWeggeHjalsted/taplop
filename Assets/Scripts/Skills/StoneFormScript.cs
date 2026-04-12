using UnityEngine;

public class StoneFormScript : MonoBehaviour, SkillScript, EnchantmentScript
{
    private string skillName;
    private string skillType;
    private string description;
    private float range;
    private float radius;
    private float distance;
    private int skillDuration;
    private int stunDuration;
    private int cooldown;
    private Sprite skillSprite;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject player;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    private int _skillBarPosition;
    public int skillBarPosition
    {
        get
        {
            return _skillBarPosition;
        }
        set
        {
            _skillBarPosition = value;
        }
    }

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

    public float GetRadius()
    {
        return radius;
    }

    public float GetDistance()
    {
        return distance;
    }

    public int GetSkillDuration()
    {
        return skillDuration;
    }

    public int GetStunDuration()
    {
        return stunDuration;
    }

    public int GetCooldown()
    {
        return cooldown;
    }

    public Sprite GetSprite()
    {
        return skillSprite;
    }

    public int EnemyPriority(Vector3 fromPosition, GameObject enemy)
    {
        EntityScript enemyScript = enemy.GetComponent<EntityScript>();
        if (enemyScript.GetSkillCooldown(skillName) > 0)
        {
            return -1;
        }
        if (enemyScript.CurrentHealth < enemyScript.MaxHealth)
        {
            return 0;
        }
        else
        {
            return -1;
        }
    }

    public Vector3 EnemySelectTarget(Vector3 fromPosition, GameObject enemy)
    {
        return fromPosition;
    }

    public void UseSkill(Vector3 targetPosition, GameObject wielder)
    {
    }

    public void PrepareSkill(Vector3 fromPosition, GameObject wielder)
    {
        traversableTilesScript.ClearHighlights();
        SoundControllerScript.Instance.PlaySpellSound();
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        // create or extend enchantment
        Transform wielderEnchantments = wielderScript.enchantments;
        GameObject stoneFormEnchantment;
        Transform stoneFormTransform = wielderEnchantments.Find("Stone Form");
        if (stoneFormTransform != null)
        {
            stoneFormEnchantment = stoneFormTransform.gameObject;
        }
        else
        {
            GameObject stoneFormPrefab = Resources.Load<GameObject>("Prefabs/Skills/Stone Form");
            stoneFormEnchantment = Instantiate(stoneFormPrefab, wielderEnchantments);
            stoneFormEnchantment.name = "Stone Form";
        }
        EnchantmentScript enchantmentScript = stoneFormEnchantment.GetComponent<EnchantmentScript>();
        int effectiveSkillDuration = skillDuration + wielderScript.enchantmentModifiers.skillDuration;
        enchantmentScript.currentDuration += effectiveSkillDuration;
        wielderScript.DisplayEnchantments();
        wielderScript.SetSkillCooldown(skillName, cooldown);
        if (wielder == player)
        {
            turnLogicScript.hasUsedAnySkill = true;
        }
        wielderScript.UsedSkill(this, null);
    }

    // enchantment functions
    private int _currentDuration = 0;
    public int currentDuration
    {
        get
        {
            return _currentDuration;
        }
        set
        {
            _currentDuration = value;
            if (_currentDuration <= 0)
            {
                _currentDuration = 0;
            }
        }
    }

    public EntityScript.Modifiers ModifierEffects()
    {
        EntityScript.Modifiers modifiers = new EntityScript.Modifiers();
        modifiers.outgoingStunDuration = 1;
        modifiers.incomingStunDuration = -1;
        return modifiers;
    }

    public void OnAttackEffect(GameObject target, GameObject wielder)
    {
    }

    public void EndOfTurnEffect(GameObject wielder)
    {
        EntityScript wielderScript = wielder.GetComponent<EntityScript>();
        wielderScript.CurrentHealth += wielderScript.MaxHealth / 5;
    }

    public void EndEffect(GameObject wielder)
    {
    }

    void Awake()
    {
        skillName = "Stone Form";
        skillType = "Enchantment";
        description = "Reduce incoming stun durations by 1, increase outgoing stun durations by 1, and heal 20% of max health at end of turn";
        range = 0;
        radius = 0;
        distance = 0;
        skillDuration = 5;
        stunDuration = 0;
        cooldown = 10;
        skillSprite = Resources.Load<Sprite>("Skills/StoneForm");
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            traversableTiles = LevelScript.Instance.traversableTiles;
            traversableTilesScript = LevelScript.Instance.traversableTilesScript;
            enemies = LevelScript.Instance.enemies;
            enemiesScript = LevelScript.Instance.enemiesScript;
            player = LevelScript.Instance.player;
            turnLogic = LevelScript.Instance.turnLogic;
            turnLogicScript = LevelScript.Instance.turnLogicScript;
        }
    }
}
